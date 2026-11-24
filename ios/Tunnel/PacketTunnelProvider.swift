import Darwin
import Foundation
import Network
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let queue = DispatchQueue(label: "org.ganzzis.vkturn.tunnel")
    private var tunnel: Session?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        queue.async {
            guard self.tunnel == nil,
                  let configuration = self.protocolConfiguration as? NETunnelProviderProtocol,
                  let id = configuration.providerConfiguration?["profileID"] as? String,
                  let uuid = UUID(uuidString: id) else {
                completionHandler(MobileError.invalidConfiguration)
                return
            }
            do {
                let profile = try KeychainProfiles().profile(uuid)
                let session = try Session(profile: profile, provider: self, queue: self.queue, completion: completionHandler)
                self.tunnel = session
                session.start()
            } catch let error as MobileError {
                completionHandler(error)
            } catch {
                completionHandler(MobileError.secureStorage)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.tunnel?.stop()
            self.tunnel = nil
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        queue.async {
            let reply = messageData == Data("status-v1".utf8) ? self.tunnel?.diagnostic : nil
            completionHandler?(reply.map { Data($0.utf8) })
        }
    }

    func sessionFailed(_ session: Session, error: MobileError, afterStartup: Bool) {
        guard tunnel === session else { return }
        tunnel = nil
        if afterStartup { cancelTunnelWithError(error) }
    }
}

final class Session {
    private weak var provider: PacketTunnelProvider?
    private let queue: DispatchQueue
    private let connection: NWConnection
    private let network: NEPacketTunnelNetworkSettings
    private var core: UnsafeMutableRawPointer?
    private var startup: ((Error?) -> Void)?
    private var timer: DispatchSourceTimer?
    private let startupDeadline = DispatchTime.now() + .seconds(20)
    private var applying = false
    private var running = false
    private var receiving = false
    private var outbound = 0
    private var inbound = 0
    private var pendingSends = 0
    private var buffer = [UInt8](repeating: 0, count: 2048)

    var diagnostic: String {
        "IPv4 packets · sent \(outbound) · received \(inbound)"
    }

    init(profile: Profile, provider: PacketTunnelProvider, queue: DispatchQueue, completion: @escaping (Error?) -> Void) throws {
        guard profile.transport == .direct else { throw MobileError.unavailableTransport }
        let json = try profile.coreJSON()
        guard let colon = profile.endpoint.lastIndex(of: ":"),
              let number = UInt16(profile.endpoint[profile.endpoint.index(after: colon)...]),
              let port = NWEndpoint.Port(rawValue: number) else { throw MobileError.invalidProfile }
        let host = profile.endpoint[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let address = try Self.route(profile.address)
        let routes = try profile.allowedIPs.split(separator: ",").map {
            try Self.route(String($0).trimmingCharacters(in: .whitespaces))
        }
        // The endpoint is resolved and the UDP session is started before adding
        // virtual routes. The remote-address label need not be a routable IP.
        network = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: [address.address], subnetMasks: [address.mask])
        ipv4.includedRoutes = routes.map { NEIPv4Route(destinationAddress: $0.network, subnetMask: $0.mask) }
        network.ipv4Settings = ipv4
        if let dns = profile.dns {
            let servers = dns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            network.dnsSettings = NEDNSSettings(servers: servers)
        }
        network.mtu = 1280
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
        guard let handle = json.withCString({ vkt_tunnel_new($0) }) else { throw MobileError.invalidProfile }
        core = handle
        self.provider = provider
        self.queue = queue
        startup = completion
    }

    deinit {
        if let core { vkt_tunnel_free(core) }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.core != nil else { return }
            switch state {
            case .ready:
                self.receive()
                self.step(0, Data())
            case .failed:
                self.fail(.socket)
            default:
                break
            }
        }
        connection.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, self.core != nil else { return }
            if !self.running && DispatchTime.now() >= self.startupDeadline {
                self.fail(.handshakeTimeout)
            } else if case .ready = self.connection.state {
                self.step(3, Data())
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        let pending = startup
        startup = nil
        close()
        pending?(MobileError.cancelled)
    }

    private func close() {
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        running = false
        if let core {
            vkt_tunnel_free(core)
            self.core = nil
        }
    }

    private func fail(_ error: MobileError) {
        let pending = startup
        startup = nil
        close()
        provider?.sessionFailed(self, error: error, afterStartup: pending == nil)
        pending?(error)
    }

    private func receive() {
        guard !receiving else { return }
        receiving = true
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.core != nil else { return }
            self.receiving = false
            if error != nil {
                self.fail(.socket)
                return
            }
            if let data, !data.isEmpty {
                if self.step(2, data) == 1 {
                    // BoringTun can have more queued datagrams after a handshake.
                    for _ in 0..<256 {
                        if self.step(2, Data()) != 1 { break }
                    }
                }
                self.installRoutesIfAuthenticated()
            }
            self.receive()
        }
    }

    private func installRoutesIfAuthenticated() {
        guard !applying, !running, let core, vkt_tunnel_ready(core) == 1, let provider else { return }
        applying = true
        provider.setTunnelNetworkSettings(network) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard self.core != nil else { return }
                if error != nil {
                    self.fail(.networkSettings)
                } else {
                    self.running = true
                    let pending = self.startup
                    self.startup = nil
                    pending?(nil)
                    self.readPackets()
                }
            }
        }
    }

    private func readPackets() {
        provider?.packetFlow.readPackets { [weak self] packets, families in
            guard let self else { return }
            self.queue.async {
                guard self.running, self.core != nil else { return }
                for (packet, family) in zip(packets, families) where family.int32Value == AF_INET && self.pendingSends < 256 {
                    if self.step(1, packet) == 1 { self.outbound += 1 }
                }
                self.readPackets()
            }
        }
    }

    @discardableResult
    private func step(_ operation: Int32, _ data: Data) -> Int32 {
        guard let core else { return -1 }
        var written = 0
        let event = data.withUnsafeBytes { input in
            buffer.withUnsafeMutableBufferPointer { output in
                vkt_tunnel_step(core, operation, input.bindMemory(to: UInt8.self).baseAddress,
                                data.count, output.baseAddress, output.count, &written)
            }
        }
        if event == 1 && pendingSends < 256 {
            pendingSends += 1
            connection.send(content: Data(buffer.prefix(written)), completion: .contentProcessed { [weak self] error in
                guard let self, self.core != nil else { return }
                self.pendingSends -= 1
                if error != nil { self.fail(.socket) }
            })
        } else if event == 2 && running {
            if provider?.packetFlow.writePackets([Data(buffer.prefix(written))], withProtocols: [NSNumber(value: AF_INET)]) == true {
                inbound += 1
            }
        }
        return event
    }

    private static func route(_ cidr: String) throws -> (address: String, mask: String, network: String) {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else {
            throw MobileError.invalidProfile
        }
        let bytes = parts[0].split(separator: ".").compactMap { UInt8($0) }
        guard bytes.count == 4 else { throw MobileError.invalidProfile }
        let bits: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        let maskBytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: bits >> $0) }
        let network = zip(bytes, maskBytes).map { String($0.0 & $0.1) }.joined(separator: ".")
        return (String(parts[0]), maskBytes.map { String($0) }.joined(separator: "."), network)
    }
}

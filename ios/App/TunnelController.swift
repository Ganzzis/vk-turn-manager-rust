import Combine
import Foundation
import NetworkExtension

@MainActor
final class TunnelController: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var activeID: UUID?
    @Published private(set) var diagnostic = ""
    @Published private(set) var starting = false

    private var manager: NETunnelProviderManager?
    private var configuration: NETunnelProviderProtocol? { manager?.protocolConfiguration as? NETunnelProviderProtocol }
    private var providerID: String { (Bundle.main.bundleIdentifier ?? "") + ".packet-tunnel" }

    var busy: Bool {
        starting || [.connecting, .connected, .reasserting, .disconnecting].contains(status)
    }

    var title: String {
        if starting { return "Starting tunnel" }
        switch status {
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reasserting: return "Reconnecting"
        case .disconnecting: return "Disconnecting"
        default: return "Disconnected"
        }
    }

    func load() async throws {
        let configurations = try await NETunnelProviderManager.loadAllFromPreferences()
        manager = configurations.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID
        }
        refresh()
    }

    func refresh() {
        guard let manager else { return }
        status = manager.connection.status
        let configuredID = configuration?.providerConfiguration?["profileID"] as? String
        activeID = busy ? configuredID.flatMap { UUID(uuidString: $0) } : nil
        if status == .connected {
            diagnostic = "WireGuard authenticated and IPv4 routes installed."
        } else if status == .disconnected {
            (manager.connection as? NETunnelProviderSession)?.fetchLastDisconnectError { [weak self] error in
                guard let error = error as NSError? else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.status == .disconnected else { return }
                    self.diagnostic = error.domain == MobileError.errorDomain
                        ? MobileError(rawValue: error.code)?.errorDescription ?? "Tunnel stopped."
                        : "Tunnel stopped. Check the peer and network."
                }
            }
        }
    }

    func connect(_ id: UUID, profile: Profile) async throws {
        guard !busy else { throw MobileError.busy }
        guard profile.transport == .direct || profile.relay != nil else { throw MobileError.unavailableTransport }
        _ = try profile.coreJSON()
        starting = true
        diagnostic = ""
        defer { starting = false; refresh() }
        let selected = manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerID
        proto.providerConfiguration = ["profileID": id.uuidString]
        proto.serverAddress = "WireGuard"
        selected.protocolConfiguration = proto
        selected.localizedDescription = "VK TURN Manager"
        selected.isEnabled = true
        try await selected.saveToPreferences()
        try await selected.loadFromPreferences()
        manager = selected
        guard let session = selected.connection as? NETunnelProviderSession else {
            throw MobileError.invalidConfiguration
        }
        try session.startTunnel(options: nil)
    }

    func refreshDiagnostics() {
        guard status == .connected, let session = manager?.connection as? NETunnelProviderSession else { return }
        try? session.sendProviderMessage(Data("status-v1".utf8)) { [weak self] reply in
            guard let reply, let text = String(data: reply, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.status == .connected else { return }
                self.diagnostic = text
            }
        }
    }

    func stop() { manager?.connection.stopVPNTunnel() }
}

import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH

private final class PinnedHost: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let expected: String?
    private let lock = NSLock()
    private var observed: String?
    init(_ expected: String?) { self.expected = expected }

    var fingerprint: String? {
        lock.lock(); defer { lock.unlock() }
        return observed
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let wire = String(openSSHPublicKey: hostKey).split(separator: " ")
        guard wire.count >= 2, let blob = Data(base64Encoded: String(wire[1])) else {
            validationCompletePromise.fail(ManagerError.ssh)
            return
        }
        let fingerprint = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        lock.lock()
        observed = fingerprint
        lock.unlock()
        if fingerprint == expected { validationCompletePromise.succeed(()) }
        else { validationCompletePromise.fail(ManagerError.hostKeyChanged) }
    }
}

final class SSH: @unchecked Sendable {
    private let client: SSHClient
    private let password: String?
    private init(_ client: SSHClient, password: String?) {
        self.client = client
        self.password = password
    }

    static func open(_ server: Server, _ credentials: Credentials) async throws -> SSH {
        try server.validate()
        try credentials.validate()
        let authentication: @Sendable () -> SSHAuthenticationMethod
        if credentials.method == .password {
            authentication = { .passwordBased(username: server.user, password: credentials.password) }
        } else {
            let key: Curve25519.Signing.PrivateKey
            do {
                key = try Curve25519.Signing.PrivateKey(
                    sshEd25519: credentials.privateKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    decryptionKey: credentials.passphrase.isEmpty ? nil : Data(credentials.passphrase.utf8))
            } catch { throw ManagerError.badPrivateKey }
            authentication = { .ed25519(username: server.user, privateKey: key) }
        }
        let validator = PinnedHost(server.hostKey)
        var settings = SSHClientSettings(host: server.host, port: server.port,
            authenticationMethod: authentication, hostKeyValidator: .custom(validator))
        settings.connectTimeout = .seconds(12)
        do {
            let client = try await SSHClient.connect(to: settings)
            return SSH(client, password: server.user == "root" ? nil : credentials.elevationPassword)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let observed = validator.fingerprint {
                if server.hostKey == nil { throw ManagerError.hostKeyRequired(HostKey(fingerprint: observed)) }
                if observed != server.hostKey { throw ManagerError.hostKeyChanged }
            }
            throw ManagerError.ssh
        }
    }

    func close() async { try? await client.close() }

    func command(_ body: String, privileged: Bool = false, seconds: Int = 30) async throws -> String {
        let marker = "VK_RESULT_" + UUID().uuidString
        let privilege: String
        if privileged {
            let sudo = password == nil ? "sudo -n --" : "sudo -k -S -p '' --"
            let script = quote("exec </dev/null; printf 'VK_PRIVILEGED\\n'; " + body)
            privilege = "if [ \"$(id -u)\" -eq 0 ]; then /bin/bash -c \(script); else \(sudo) /bin/bash -c \(script); fi"
        } else {
            privilege = "/bin/bash -c \(quote(body))"
        }
        let full = "umask 077; \(privilege); code=$?; printf '\\n\(marker):%s\\n' \"$code\""
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var output = Data()
                try await self.client.withExec(full) { inbound, outbound in
                    if privileged, let password = self.password {
                        try await outbound.write(ByteBuffer(string: password + "\n"))
                    }
                    for try await part in inbound {
                        if case .stdout(let buffer) = part {
                            guard output.count + buffer.readableBytes <= 512 * 1024 else { throw ManagerError.badReply }
                            output.append(contentsOf: buffer.readableBytesView)
                        }
                    }
                }
                let response = String(decoding: output, as: UTF8.self)
                guard let separator = response.range(of: "\n\(marker):", options: .backwards),
                      let code = Int(response[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
                else { throw ManagerError.badReply }
                var result = String(response[..<separator.lowerBound])
                if result.hasPrefix("VK_PRIVILEGED\n") { result.removeFirst("VK_PRIVILEGED\n".count) }
                else if privileged && code == 1 { throw ManagerError.sudo }
                if code != 0 { throw ManagerError.remote(code) }
                return result
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                await self.close()
                throw ManagerError.timeout
            }
            defer { group.cancelAll() }
            guard let reply = try await group.next() else { throw ManagerError.badReply }
            return reply
        }
    }

    func stage<T>(_ work: (String) async throws -> T) async throws -> T {
        let path = try await command("mktemp -d /tmp/vk-manager.XXXXXXXX")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.range(of: "^/tmp/vk-manager\\.[A-Za-z0-9]{8}$", options: .regularExpression) != nil,
              !path.contains(where: \.isNewline) else { throw ManagerError.badReply }
        do {
            let result = try await work(path)
            _ = try? await command("rm -rf -- \(quote(path))")
            return result
        } catch {
            _ = try? await command("rm -rf -- \(quote(path))")
            throw error
        }
    }

    func upload(_ files: [(String, Data)], to directory: String) async throws {
        let sftp = try await client.openSFTP()
        do {
            for (name, data) in files {
                try Task.checkCancellation()
                try await sftp.withFile(filePath: directory + "/" + name,
                                        flags: [.write, .create, .forceCreate]) { file in
                    try await file.write(ByteBuffer(bytes: data))
                }
            }
            try await sftp.close()
        } catch {
            try? await sftp.close()
            throw error
        }
    }
}

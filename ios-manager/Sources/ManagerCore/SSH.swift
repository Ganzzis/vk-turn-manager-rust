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
    private let diagnostics: DiagnosticLog
    private init(_ client: SSHClient, password: String?, diagnostics: DiagnosticLog) {
        self.client = client
        self.password = password
        self.diagnostics = diagnostics
    }

    static func open(_ server: Server, _ credentials: Credentials, diagnostics: DiagnosticLog = DiagnosticLog()) async throws -> SSH {
        diagnostics.record(.connect(credentials.method))
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
            diagnostics.record(.authenticated)
            return SSH(client, password: server.user == "root" ? nil : credentials.elevationPassword, diagnostics: diagnostics)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let observed = validator.fingerprint {
                if server.hostKey == nil {
                    diagnostics.record(.hostUnconfirmed)
                    throw ManagerError.hostKeyRequired(HostKey(fingerprint: observed))
                }
                if observed != server.hostKey {
                    diagnostics.record(.hostChanged)
                    throw ManagerError.hostKeyChanged
                }
                diagnostics.record(.authenticationFailed)
                throw ManagerError.authentication
            }
            diagnostics.record(.connectFailed)
            throw ManagerError.ssh
        }
    }

    func close() async { try? await client.close() }

    func command(_ body: String, privileged: Bool = false, seconds: Int = 30) async throws -> String {
        let marker = "VK_RESULT_" + UUID().uuidString
        let bash = "/usr/bin/env -u BASH_ENV /bin/bash --noprofile --norc -c"
        let privilege: String
        if privileged {
            let sudo = password == nil ? "sudo -n --" : "sudo -k -S -p '' --"
            let rootScript = quote("exec </dev/null; printf 'VK_PRIVILEGED_ROOT\\n'; " + body)
            let sudoScript = quote("exec </dev/null; printf 'VK_PRIVILEGED_SUDO\\n'; " + body)
            privilege = "if [ \"$(id -u)\" -eq 0 ]; then \(bash) \(rootScript); else \(sudo) \(bash) \(sudoScript); fi"
        } else {
            privilege = "\(bash) \(quote(body))"
        }
        let frame = "umask 077; printf '\\n\(marker):BEGIN\\n'; \(privilege); code=$?; printf '\\n\(marker):END:%s\\n' \"$code\""
        // Use Bash even when the account's login shell only forwards the command.
        let full = "\(bash) \(quote(frame))"
        diagnostics.record(.command)
        return try await deadline(seconds) {
            var output = Data()
            var errors = Data()
            defer {
                self.diagnostics.record(.streams(output.count, errors.count))
                if !errors.isEmpty { self.diagnostics.record(.stderr(.classify(errors))) }
            }
            do {
                try await self.client.withExec(full) { inbound, outbound in
                    if privileged, let password = self.password {
                        try await outbound.write(ByteBuffer(string: password + "\n"))
                    }
                    for try await part in inbound {
                        switch part {
                        case .stdout(let buffer):
                            guard output.count + buffer.readableBytes <= 512 * 1024 else { throw FrameFault.outputLimit }
                            output.append(contentsOf: buffer.readableBytesView)
                        case .stderr(let buffer):
                            errors.append(contentsOf: buffer.readableBytesView.prefix(max(0, 8192 - errors.count)))
                        }
                    }
                }
            } catch let error as ChannelError where error == .alreadyClosed {
                // A complete frame is still required if OpenSSH closes first.
            } catch let fault as FrameFault {
                self.diagnostics.record(.invalidFrame(fault))
                throw ManagerError.badReply
            } catch {
                self.diagnostics.record(.protocolFailed)
                throw error
            }
            let reply: CommandReply
            do { reply = try CommandReply.parse(output, marker: marker) }
            catch let fault as FrameFault {
                self.diagnostics.record(.invalidFrame(fault))
                throw ManagerError.badReply
            }
            self.diagnostics.record(.exit(reply.exit))
            var result = reply.stdout
            if privileged {
                let root = result.hasPrefix("VK_PRIVILEGED_ROOT\n")
                let prefix = root ? "VK_PRIVILEGED_ROOT\n" : "VK_PRIVILEGED_SUDO\n"
                guard result.hasPrefix(prefix) else {
                    self.diagnostics.record(.privilegeFailed)
                    throw ManagerError.sudo
                }
                self.diagnostics.record(.privileges(root))
                result.removeFirst(prefix.count)
            }
            if reply.exit != 0 { throw ManagerError.remote(reply.exit) }
            return result
        }
    }

    private func deadline<T: Sendable>(_ seconds: Int, work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: work)
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                self.diagnostics.record(.timeout)
                await self.close()
                throw ManagerError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ManagerError.badReply }
            return result
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
        try await deadline(180) {
            let sftp = try await self.client.openSFTP()
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
                self.diagnostics.record(.sftpFailed)
                throw error
            }
        }
    }
}

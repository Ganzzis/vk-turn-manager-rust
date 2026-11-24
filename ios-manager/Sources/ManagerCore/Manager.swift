import Foundation
import Crypto

public struct Manager: Sendable {
    public let server: Server
    public let credentials: Credentials

    public init(server: Server, credentials: Credentials) {
        self.server = server
        self.credentials = credentials
    }

    private func session<T>(_ work: (SSH) async throws -> T) async throws -> T {
        let ssh = try await SSH.open(server, credentials)
        do {
            let result = try await withTaskCancellationHandler {
                try await work(ssh)
            } onCancel: {
                Task { await ssh.close() }
            }
            await ssh.close()
            return result
        } catch {
            await ssh.close()
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? ManagerError { throw error }
            throw ManagerError.ssh
        }
    }

    private static let cli = "/usr/local/bin/vk-turn-manager"
    private static let detect = """
    . /etc/os-release
    printf '%s %s %s\\n' "$ID" "$VERSION_ID" "$(uname -m)"
    if test -f /etc/vk-turn-manager/wg-vk.conf &&
       printf 'vk-turn-manager installation\\n' | cmp -s - /etc/vk-turn-manager/managed; then
        printf 'managed\\n'
        if test -x /usr/local/bin/vk-turn-manager; then /usr/local/bin/vk-turn-manager --version; else printf '-\\n'; fi
    elif test -e /etc/vk-turn-manager || test -e /etc/wireguard/wg-vk.conf ||
         test -e /sys/class/net/wg-vk || test -e /etc/systemd/system/vk-turn-srtp.service; then
        printf 'foreign\\n-\\n'
    else
        printf 'absent\\n-\\n'
    fi
    for unit in vk-turn-wireguard vk-turn-srtp vk-turn-network; do
        state=$(systemctl show --property=ActiveState --value "$unit.service" 2>/dev/null) || state=inactive
        printf '%s\\n' "${state:-inactive}"
    done
    """

    private func status(_ ssh: SSH) async throws -> ServerStatus {
        let lines = try await ssh.command(Self.detect, privileged: true)
            .split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count == 6, let installation = Installation(rawValue: lines[1]) else {
            throw ManagerError.badReply
        }
        let platform = lines[0].split(separator: " ").map(String.init)
        guard platform.count == 3, platform[0] == "ubuntu", ["24.04", "26.04"].contains(platform[1])
        else { throw ManagerError.unsupported }
        let arch: String
        switch platform[2] {
        case "x86_64": arch = "amd64"
        case "aarch64": arch = "arm64"
        default: throw ManagerError.unsupported
        }
        return ServerStatus(system: "Ubuntu " + platform[1], architecture: arch,
                            installation: installation, version: lines[2],
                            wireguard: lines[3], srtp: lines[4], nat: lines[5])
    }

    public func status() async throws -> ServerStatus { try await session { try await status($0) } }

    public func install(_ bundle: ServerBundle, update: Bool = false,
                        progress: @Sendable (String) async -> Void) async throws {
        await progress("Подключение и проверка сервера")
        try await session { ssh in
            let current = try await status(ssh)
            guard current.installation == (update ? .managed : .absent) else {
                throw ManagerError.notManaged
            }
            let files = try bundle.files(for: current.architecture)
            try await ssh.stage { staging in
                await progress("Передача пакета \(current.architecture) по SFTP")
                try await ssh.upload(files.map { ($0.name, $0.data) }, to: staging)
                let sums = files.map { "\($0.digest)  \($0.name)" }.joined(separator: "\n") + "\n"
                let sources = files.map { quote(staging + "/" + $0.name) }.joined(separator: " ")
                let upstream = "server-linux-\(current.architecture)"
                let mode = update ? "update" : "install"
                await progress(update ? "Проверка пакета и обновление SRTP" : "Проверка пакета, установка WireGuard, SRTP и NAT")
                _ = try await ssh.command("""
                set -e
                stage=$(mktemp -d /tmp/vk-manager-root.XXXXXXXX)
                trap 'rm -rf -- "$stage"' EXIT
                trap 'exit 1' HUP TERM INT
                cp -- \(sources) "$stage/"
                cd "$stage"
                printf '%s' \(quote(sums)) | sha256sum --check --status
                export DEBIAN_FRONTEND=noninteractive
                VK_TURN_SRTP_FILE="$stage/\(upstream)" bash install.sh \(mode) v0.3.0 "$stage"
                """, privileged: true, seconds: 720)
            }
            await progress("Проверка запущенных служб")
            let result = try await status(ssh)
            guard result.installation == .managed, result.wireguard == "active", result.srtp == "active",
                  update || result.nat == "active" else { throw ManagerError.badReply }
        }
    }

    public func peers() async throws -> [Peer] {
        try await session { ssh in
            let result = try await ssh.command(Self.cli + " client list", privileged: true)
            do { return try JSONDecoder().decode([Peer].self, from: Data(result.utf8)) }
            catch { throw ManagerError.badReply }
        }
    }

    public func changePeer(_ name: String, remove: Bool = false) async throws {
        try checkClient(name)
        let verb = remove ? "remove" : "add"
        _ = try await session { try await $0.command("\(Self.cli) client \(verb) \(quote(name))", privileged: true) }
    }

    public func profile(_ name: String, endpoint: String, invite: String) async throws -> String {
        try checkClient(name)
        try checkEndpoint(endpoint)
        try checkInvite(invite)
        return try await session { ssh in
            try await ssh.stage { staging in
                try await ssh.upload([("invite", Data(invite.utf8))], to: staging)
                let source = quote(staging + "/invite")
                let digest = SHA256.hash(data: Data(invite.utf8)).map { String(format: "%02x", $0) }.joined()
                let output = try await ssh.command("""
                set -e
                stage=$(mktemp -d /tmp/vk-manager-profile.XXXXXXXX)
                trap 'rm -rf -- "$stage"' EXIT
                trap 'exit 1' HUP TERM INT
                install -m 0600 -- \(source) "$stage/invite"
                printf '%s  %s\\n' \(quote(digest)) "$stage/invite" | sha256sum --check --status
                \(Self.cli) client export \(quote(name)) --srtp-endpoint \(quote(endpoint)) --vk-link-file "$stage/invite" --output "$stage/profile" >/dev/null
                cat "$stage/profile"
                """, privileged: true).trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "vkturnproxy://import?data="
                guard output.hasPrefix(prefix), output.utf8.count <= 4096,
                      !output.dropFirst(prefix.count).isEmpty,
                      output.dropFirst(prefix.count).utf8.allSatisfy({
                        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 95].contains($0)
                      }) else { throw ManagerError.badReply }
                return output
            }
        }
    }

    public func connections() async throws -> [Connection] {
        let output = try await session { ssh in
            try await ssh.command("""
            set -e
            for field in endpoints latest-handshakes transfer; do
                printf '%s\\n' "$field"
                wg show wg-vk "$field"
            done
            """, privileged: true)
        }
        return Self.parseConnections(output)
    }

    static func parseConnections(_ output: String) -> [Connection] {
        var field = ""
        var records: [String: Connection] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count == 1 { field = parts[0]; continue }
            guard parts.count >= 2 else { continue }
            var entry = records[parts[0]] ?? Connection(publicKey: parts[0])
            switch field {
            case "endpoints": entry.endpoint = parts[1] == "(none)" ? nil : parts[1]
            case "latest-handshakes":
                if let time = Double(parts[1]), time > 0 { entry.handshake = Date(timeIntervalSince1970: time) }
            case "transfer":
                if parts.count == 3 {
                    entry.received = UInt64(parts[1]) ?? 0
                    entry.sent = UInt64(parts[2]) ?? 0
                }
            default: continue
            }
            records[parts[0]] = entry
        }
        return records.values.sorted { $0.publicKey < $1.publicKey }
    }

    public func logs() async throws -> String {
        try await session { try await $0.command("journalctl --no-pager -n 100 -u vk-turn-wireguard.service -u vk-turn-srtp.service -u vk-turn-network.service", privileged: true) }
    }

    public func changeService(_ action: ServiceAction) async throws {
        try await session { ssh in
            guard try await status(ssh).installation == .managed else { throw ManagerError.notManaged }
            let command: String
            switch action {
            case .start: command = "systemctl start vk-turn-srtp.service"
            case .stop: command = "systemctl stop vk-turn-srtp.service vk-turn-wireguard.service"
            case .restart: command = "systemctl restart vk-turn-wireguard.service vk-turn-srtp.service"
            case .enableNAT: command = Self.cli + " network enable"
            case .remove: command = Self.cli + " uninstall"
            }
            _ = try await ssh.command(command, privileged: true, seconds: 150)
        }
    }
}

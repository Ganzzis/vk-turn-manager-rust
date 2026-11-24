import XCTest
import Foundation
@testable import ManagerCore

final class ManagerTests: XCTestCase {
    func testInputsAndShellQuoting() throws {
        var server = Server()
        server.name = "Fixture"
        server.host = "2001:db8::4"
        XCTAssertNoThrow(try server.validate())
        XCTAssertEqual(server.defaultEndpoint, "[2001:db8::4]:56004")
        server.host = "host;id"
        XCTAssertThrowsError(try server.validate())
        XCTAssertEqual(quote("a'b"), "'a'\\''b'")
        XCTAssertNoThrow(try checkClient("phone-1"))
        XCTAssertThrowsError(try checkClient("phone\n"))
        XCTAssertThrowsError(try checkInvite("https://example.test/call/join/token"))
        XCTAssertThrowsError(try checkInvite("https://vk.com/call/join/token?x=1"))
        XCTAssertNoThrow(try checkInvite("https://vk.ru/call/join/synthetic-token"))
        XCTAssertThrowsError(try checkEndpoint("vpn.example:0"))
    }

    func testConnectionOutputUsesOnlyPublicFields() {
        let response = """
        endpoints
        alpha\t192.0.2.1:212
        bravo\t(none)
        latest-handshakes
        alpha\t1700000000
        bravo\t0
        transfer
        alpha\t30\t50
        bravo\t0\t0
        """
        let connections = Manager.parseConnections(response)
        XCTAssertEqual(connections.map(\.publicKey), ["alpha", "bravo"])
        XCTAssertEqual(connections.first?.handshake?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(connections.first?.received, 30)
        XCTAssertEqual(connections.first?.sent, 50)
        XCTAssertNil(connections.last?.endpoint)
        XCTAssertNil(connections.last?.handshake)
    }

    func testInvalidBundleRejectedBeforeUpload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("00  install.sh\n".utf8).write(to: folder.appendingPathComponent("SHA256SUMS"))
        try Data("echo changed".utf8).write(to: folder.appendingPathComponent("install.sh"))
        XCTAssertThrowsError(try ServerBundle(directory: folder).files(for: "amd64")) {
            XCTAssertEqual($0 as? ManagerError, .bundle)
        }
    }

    func testCommandFrameIgnoresBannersAndRequiresACompleteExitMarker() throws {
        let marker = "VK_RESULT_FIXTURE"
        let valid = "startup banner\n" + "\nVK_RESULT_FIXTURE:BEGIN\nvalue\n\nVK_RESULT_FIXTURE:END:42\nlogout banner"
        let reply = try CommandReply.parse(Data(valid.utf8), marker: marker)
        XCTAssertEqual(reply.stdout, "value\n")
        XCTAssertEqual(reply.exit, 42)
        for (text, expected) in [
            ("VK_RESULT_FIXTURE:END:0\n", FrameFault.missingStart),
            ("\nVK_RESULT_FIXTURE:BEGIN\nvalue", .missingEnd),
            ("\nVK_RESULT_FIXTURE:BEGIN\n\nVK_RESULT_FIXTURE:END:0", .missingEnd),
            ("\nVK_RESULT_FIXTURE:BEGIN\n\nVK_RESULT_FIXTURE:END:999\n", .invalidExit)
        ] {
            XCTAssertThrowsError(try CommandReply.parse(Data(text.utf8), marker: marker)) {
                XCTAssertEqual($0 as? FrameFault, expected)
            }
        }
    }

    func testDiagnosticsOnlyKeepAllowlistedInformation() {
        let log = DiagnosticLog()
        let secret = "synthetic-private-secret vkturnproxy://import?data=synthetic"
        log.record(.stderr(.classify(Data(("sudo: " + secret).utf8))))
        log.record(.invalidFrame(.missingEnd))
        log.markFailure(ManagerError.hostKeyRequired(HostKey(fingerprint: secret)))
        XCTAssertTrue(log.text().contains("sudo"))
        XCTAssertTrue(log.text().contains("Нет маркера завершения"))
        XCTAssertFalse(log.text().contains(secret))
        for _ in 0..<125 { log.markCompletion() }
        XCTAssertEqual(log.text().split(whereSeparator: \.isNewline).count, 100)
    }

    func testDisposableUbuntuOverSSH() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["VK_MANAGER_FIXTURE_PORT"] != nil, "Requires disposable Ubuntu fixture")
        var server = Server()
        server.name = "Synthetic"
        server.host = "127.0.0.1"
        server.port = try XCTUnwrap(env["VK_MANAGER_FIXTURE_PORT"].flatMap(Int.init))
        server.user = "ubuntu"
        var credentials = Credentials()
        credentials.password = try XCTUnwrap(env["VK_MANAGER_FIXTURE_PASSWORD"])
        let pin = try XCTUnwrap(env["VK_MANAGER_FIXTURE_PIN"])
        print("Checking host key rejection")
        do {
            _ = try await Manager(server: server, credentials: credentials).status()
            XCTFail("Host authenticated without explicit pin")
        } catch ManagerError.hostKeyRequired(let observed) {
            XCTAssertEqual(observed.fingerprint, pin)
        }
        server.hostKey = "SHA256:incorrect"
        do {
            _ = try await Manager(server: server, credentials: credentials).status()
            XCTFail("Changed host key accepted")
        } catch ManagerError.hostKeyChanged {}
        server.hostKey = pin
        print("Checking password login and sudo")
        let passwordManager = Manager(server: server, credentials: credentials)
        let initial = try await passwordManager.status()
        XCTAssertEqual(initial.installation, .absent)
        var root = server
        root.user = "root"
        root.hostKey = nil
        let rootLog = DiagnosticLog()
        do {
            _ = try await Manager(server: root, credentials: credentials, diagnostics: rootLog).status()
            XCTFail("Root authenticated without explicit pin")
        } catch ManagerError.hostKeyRequired(let observed) {
            XCTAssertEqual(observed.fingerprint, pin)
            root.hostKey = observed.fingerprint
        }
        rootLog.markHostConfirmed()
        let rootManager = Manager(server: root, credentials: credentials, diagnostics: rootLog)
        let cleanAsRoot = try await rootManager.status()
        XCTAssertEqual(cleanAsRoot.installation, .absent)
        var badPassword = credentials
        badPassword.password = "synthetic-incorrect-password"
        do {
            _ = try await Manager(server: root, credentials: badPassword, diagnostics: rootLog).status()
            XCTFail("Root authenticated with an incorrect password")
        } catch ManagerError.authentication {}
        let bundle = ServerBundle(directory: URL(fileURLWithPath: try XCTUnwrap(env["VK_MANAGER_FIXTURE_BUNDLE"])))
        try await rootManager.install(bundle) { phase in print(phase) }
        let active = try await passwordManager.status()
        XCTAssertEqual(active.srtp, "active")
        XCTAssertEqual(active.wireguard, "active")
        XCTAssertEqual(active.nat, "active")

        let rootSSH = try await SSH.open(root, credentials, diagnostics: rootLog)
        defer { Task { await rootSSH.close() } }
        let stream = try await rootSSH.command("printf '%s' matching-stdout; printf '%s' synthetic-stderr >&2")
        XCTAssertEqual(stream, "matching-stdout")
        do {
            _ = try await rootSSH.command("printf '%s' 'fixture: invalid option synthetic-stderr' >&2; exit 34", privileged: true)
            XCTFail("Nonzero exit was ignored")
        } catch ManagerError.remote(34) {}
        // An earlier server can be installed from a checkout without a system CLI.
        _ = try await rootSSH.command("mv /usr/local/bin/vk-turn-manager /root/vk-turn-manager-fixture", privileged: true)
        let legacy = try await rootManager.status()
        XCTAssertEqual(legacy.installation, .managed)
        XCTAssertEqual(legacy.version, "-")
        XCTAssertEqual(legacy.wireguard, "active")
        XCTAssertEqual(legacy.srtp, "active")
        XCTAssertEqual(legacy.nat, "active")
        _ = try await rootSSH.command("mv /root/vk-turn-manager-fixture /usr/bin/vk-turn-manager", privileged: true)
        let distroPath = try await rootManager.status()
        XCTAssertEqual(distroPath.version, "vk-turn-manager 0.3.0")
        let distroPeers = try await rootManager.peers()
        XCTAssertTrue(distroPeers.isEmpty)
        _ = try await rootSSH.command("""
        set -e
        mv /usr/bin/vk-turn-manager /root/vk-turn-manager-fixture
        cat >/usr/bin/vk-turn-manager <<'LEGACY'
        #!/bin/bash
        if [[ $1 == --version ]]; then printf '%s\\n' 'unsupported version flag' >&2; exit 2; fi
        exec /root/vk-turn-manager-fixture "$@"
        LEGACY
        chmod 0755 /usr/bin/vk-turn-manager
        """, privileged: true)
        let legacyVersion = try await rootManager.status()
        XCTAssertEqual(legacyVersion.version, "unknown")
        let legacyPeers = try await rootManager.peers()
        XCTAssertTrue(legacyPeers.isEmpty)
        _ = try await rootSSH.command("rm /usr/bin/vk-turn-manager && mv /root/vk-turn-manager-fixture /usr/local/bin/vk-turn-manager", privileged: true)
        let diagnosticText = rootLog.text()
        XCTAssertTrue(diagnosticText.contains("Авторизация SSH успешна"))
        XCTAssertTrue(diagnosticText.contains("команда отклонила аргумент"))
        XCTAssertTrue(diagnosticText.contains("системных каталогах"))
        for secret in [credentials.password, badPassword.password, "synthetic-stderr", "synthetic shell banner", pin] {
            XCTAssertFalse(diagnosticText.contains(secret), "Diagnostic log retained sensitive fixture data")
        }

        var key = Credentials()
        key.method = .key
        key.privateKey = try String(contentsOfFile: XCTUnwrap(env["VK_MANAGER_FIXTURE_KEY"]), encoding: .utf8)
        key.sudoPassword = credentials.password
        let manager = Manager(server: server, credentials: key)
        print("Checking OpenSSH key login and client export")
        try await manager.changePeer("phone")
        let peers = try await manager.peers()
        XCTAssertEqual(peers.map(\.name), ["phone"])
        let args = ("phone", server.defaultEndpoint, "https://vk.ru/call/join/synthetic")
        let profile = try await manager.profile(args.0, endpoint: args.1, invite: args.2)
        let suffix = String(profile.dropFirst("vkturnproxy://import?data=".count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let decoded = try XCTUnwrap(Data(base64Encoded: suffix + String(repeating: "=", count: (4 - suffix.count % 4) % 4)))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded) as? [String: Any])
        let settings = try XCTUnwrap(payload["settings"] as? [String: Any])
        XCTAssertEqual(payload["version"] as? Int, 1)
        XCTAssertEqual(settings["useSrtp"] as? Bool, true)
        XCTAssertEqual(settings["vkLink"] as? String, args.2)
        print("Checking real WireGuard handshake and byte counters")
        let fixture = try await SSH.open(server, key)
        do {
            _ = try await fixture.command("""
            set -e
            stage=$(mktemp -d)
            trap 'rm -rf -- "$stage"' EXIT
            /usr/local/bin/vk-turn-manager client export phone --wg-endpoint 192.0.2.1:51820 --output "$stage/client.conf" >/dev/null
            WG_CLIENT_CONF="$stage/client.conf" bash /home/ubuntu/network-dataplane.sh
            """, privileged: true)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
        let connections = try await manager.connections()
        XCTAssertEqual(connections.first?.publicKey, peers.first?.publicKey)
        XCTAssertNotNil(connections.first?.handshake)
        XCTAssertGreaterThan(connections.first?.received ?? 0, 0)
        XCTAssertGreaterThan(connections.first?.sent ?? 0, 0)
        try await manager.install(bundle, update: true) { phase in print(phase) }
        let retained = try await manager.profile(args.0, endpoint: args.1, invite: args.2)
        XCTAssertTrue(retained == profile, "The profile changed across update")
        try await manager.changeService(.stop)
        let stopped = try await manager.status()
        XCTAssertEqual(stopped.srtp, "inactive")
        try await manager.changeService(.start)
        try await manager.changeService(.restart)
        let journal = try await manager.logs()
        XCTAssertFalse(journal.contains(args.2))
        XCTAssertFalse(journal.contains(credentials.password))
        try await manager.changePeer("phone", remove: true)
        let remaining = try await manager.peers()
        XCTAssertTrue(remaining.isEmpty)
        try await manager.changeService(.remove)
        let removed = try await manager.status()
        XCTAssertEqual(removed.installation, .absent)
    }
}

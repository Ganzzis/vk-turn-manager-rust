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
        let passwordManager = Manager(server: server, credentials: credentials)
        let initial = try await passwordManager.status()
        XCTAssertEqual(initial.installation, .absent)
        let bundle = ServerBundle(directory: URL(fileURLWithPath: try XCTUnwrap(env["VK_MANAGER_FIXTURE_BUNDLE"])))
        try await passwordManager.install(bundle) { _ in }
        let active = try await passwordManager.status()
        XCTAssertEqual(active.srtp, "active")
        XCTAssertEqual(active.wireguard, "active")
        XCTAssertEqual(active.nat, "active")

        var key = Credentials()
        key.method = .key
        key.privateKey = try String(contentsOfFile: XCTUnwrap(env["VK_MANAGER_FIXTURE_KEY"]), encoding: .utf8)
        key.sudoPassword = credentials.password
        let manager = Manager(server: server, credentials: key)
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
        let connections = try await manager.connections()
        XCTAssertEqual(connections.first?.publicKey, peers.first?.publicKey)
        try await manager.install(bundle, update: true) { _ in }
        let retained = try await manager.profile(args.0, endpoint: args.1, invite: args.2)
        XCTAssertTrue(retained == profile, "The profile changed across update")
        try await manager.changeService(.stop)
        let stopped = try await manager.status()
        XCTAssertEqual(stopped.srtp, "inactive")
        try await manager.changeService(.start)
        try await manager.changeService(.restart)
        let journal = try await manager.logs()
        XCTAssertFalse(journal.contains(args.2))
        try await manager.changePeer("phone", remove: true)
        let remaining = try await manager.peers()
        XCTAssertTrue(remaining.isEmpty)
        try await manager.changeService(.remove)
        let removed = try await manager.status()
        XCTAssertEqual(removed.installation, .absent)
    }
}

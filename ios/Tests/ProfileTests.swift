import Foundation
import XCTest

private final class MemorySecrets: ProfileSecrets {
    var entries: [UUID: Data] = [:]
    func read(_ id: UUID) throws -> Data {
        guard let data = entries[id] else { throw MobileError.secureStorage }
        return data
    }
    func write(_ data: Data, id: UUID) throws { entries[id] = data }
    func remove(_ id: UUID) throws { entries.removeValue(forKey: id) }
}

final class ProfileTests: XCTestCase {
    private let key = Data(repeating: 17, count: 32).base64EncodedString()

    func testImportAndValidationThroughRustFFI() throws {
        let settings: [String: Any] = [
            "serverName": "Synthetic", "privateKey": key, "peerPublicKey": key,
            "tunnelAddress": "192.0.2.2/32", "peerAddress": "srtp.example:56004",
            "vkLink": "https://vk.ru/call/join/synthetic", "useSrtp": true,
            "allowedIPs": "198.51.100.0/24"
        ]
        let payload = try JSONSerialization.data(withJSONObject: ["version": 1, "type": "connection", "settings": settings])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var imported = try Profile.importLink("vkturnproxy://import?data=" + encoded)
        XCTAssertEqual(imported.transport, .srtp)
        XCTAssertEqual(imported.endpoint, "srtp.example:56004")
        XCTAssertEqual(imported.allowedIPs, "198.51.100.0/24")
        XCTAssertThrowsError(try Profile.importLink("vkturnproxy://import?data=broken"))
        XCTAssertThrowsError(try imported.connectionJSON()) { error in
            XCTAssertEqual(error as? MobileError, .unavailableTransport)
        }
        XCTAssertNil(try imported.coreJSON().withCString { vkt_tunnel_new($0) })
        imported.relay = RelayCredentials(address: "turn.example:3478", username: "fixture",
                                          password: "synthetic-token", expiresAt: "0")
        let envelope = try imported.coreJSON()
        XCTAssertThrowsError(try imported.connectionJSON()) { error in
            XCTAssertEqual(error as? MobileError, .relayCredentials)
        }
        imported.relay?.expiresAt = String(Int(Date().timeIntervalSince1970) + 120)
        XCTAssertNoThrow(try imported.connectionJSON())
        XCTAssertNotNil(envelope.withCString { vkt_tunnel_new($0) }.map { handle in
            vkt_tunnel_free(handle)
            return true
        })
        imported.relay?.certificateSha256 = "invalid"
        XCTAssertThrowsError(try imported.coreJSON())
    }

    @MainActor
    func testProfileLifecycleKeepsSecretsOutOfPreferences() async throws {
        let suite = "ProfileTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecrets()
        let store = ProfileStore(secrets: secrets, preferences: defaults)
        var profile = Profile(name: "Synthetic", address: "192.0.2.2/32",
                              privateKey: key, peerPublicKey: key, endpoint: "wg.example:51820")
        try store.save(profile, id: nil)
        let id = try XCTUnwrap(store.summaries.first?.id)
        let metadata = try XCTUnwrap(defaults.data(forKey: "connection-summaries-v1"))
        let text = String(decoding: metadata, as: UTF8.self)
        XCTAssertFalse(text.contains(key))
        XCTAssertFalse(text.contains("wg.example"))
        profile.name = "Edited"
        try store.save(profile, id: id)
        XCTAssertEqual(store.summaries.map(\.name), ["Edited"])
        XCTAssertEqual(try store.profile(id).privateKey, key)
        try store.remove(id)
        XCTAssertTrue(store.summaries.isEmpty)
        XCTAssertTrue(secrets.entries.isEmpty)
    }
}

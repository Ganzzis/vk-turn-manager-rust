import Combine
import Foundation
import Security
import ManagerCore

@MainActor
final class Vault: ObservableObject {
    @Published private(set) var servers: [Server] = []
    @Published private(set) var loadFailed = false
    private let defaults = UserDefaults.standard
    private let index = "server-manager-index-v1"

    init() {
        if let data = defaults.data(forKey: index) {
            do { servers = try JSONDecoder().decode([Server].self, from: data) }
            catch { loadFailed = true }
        }
    }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "org.ganzzis.vkturn.server-manager.ssh",
         kSecAttrAccount as String: id.uuidString]
    }

    func credentials(_ id: UUID) throws -> Credentials {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data)
        else { throw ManagerError.privateStorage }
        return credentials
    }

    func save(_ server: Server, credentials: Credentials) throws {
        guard !loadFailed else { throw ManagerError.privateStorage }
        var snapshot = servers
        if let existing = snapshot.firstIndex(where: { $0.id == server.id }) {
            snapshot[existing] = server
        } else { snapshot.append(server) }
        let metadata = try JSONEncoder().encode(snapshot)
        let data = try JSONEncoder().encode(credentials)
        let key = query(server.id)
        let status = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = key
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw ManagerError.privateStorage }
        } else if status != errSecSuccess { throw ManagerError.privateStorage }
        defaults.set(metadata, forKey: index)
        servers = snapshot
    }

    func remove(_ id: UUID) throws {
        let snapshot = servers.filter { $0.id != id }
        let metadata = try JSONEncoder().encode(snapshot)
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ManagerError.privateStorage }
        defaults.set(metadata, forKey: index)
        servers = snapshot
    }
}

import Foundation
import Combine
import Security

protocol ProfileSecrets {
    func read(_ id: UUID) throws -> Data
    func write(_ data: Data, id: UUID) throws
    func remove(_ id: UUID) throws
}

struct KeychainProfiles: ProfileSecrets {
    private func query(_ id: UUID) throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "VKKeychainGroup") as? String,
              !group.isEmpty, !group.hasPrefix(".") else { throw MobileError.secureStorage }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VKMobileProfiles",
            kSecAttrAccount as String: id.uuidString,
            kSecAttrAccessGroup as String: group
        ]
    }

    func read(_ id: UUID) throws -> Data {
        var request = try query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { throw MobileError.secureStorage }
        return data
    }

    func write(_ data: Data, id: UUID) throws {
        var request = try query(id)
        let attributes = [kSecValueData as String: data]
        let result = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if result == errSecSuccess { return }
        guard result == errSecItemNotFound else { throw MobileError.secureStorage }
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw MobileError.secureStorage }
    }

    func remove(_ id: UUID) throws {
        let result = SecItemDelete(try query(id) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw MobileError.secureStorage }
    }

    func profile(_ id: UUID) throws -> Profile {
        try JSONDecoder().decode(Profile.self, from: read(id))
    }
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var summaries: [ProfileSummary]
    private let secrets: ProfileSecrets
    private let preferences: UserDefaults
    private let key = "connection-summaries-v1"

    init(secrets: ProfileSecrets = KeychainProfiles(), preferences: UserDefaults = .standard) {
        self.secrets = secrets
        self.preferences = preferences
        summaries = preferences.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([ProfileSummary].self, from: $0) } ?? []
    }

    func profile(_ id: UUID) throws -> Profile {
        try JSONDecoder().decode(Profile.self, from: secrets.read(id))
    }

    func save(_ input: Profile, id: UUID?) throws {
        let profile = input.normalized()
        let id = id ?? UUID()
        let summary = ProfileSummary(id: id, name: profile.name, transport: profile.transport)
        var updated = summaries
        if let index = updated.firstIndex(where: { $0.id == id }) {
            updated[index] = summary
        } else {
            updated.append(summary)
        }
        let indexData = try JSONEncoder().encode(updated)
        let secretData = try Data(profile.coreJSON().utf8)
        try secrets.write(secretData, id: id)
        preferences.set(indexData, forKey: key)
        summaries = updated
    }

    func remove(_ id: UUID) throws {
        let updated = summaries.filter { $0.id != id }
        let indexData = try JSONEncoder().encode(updated)
        try secrets.remove(id)
        preferences.set(indexData, forKey: key)
        summaries = updated
    }
}

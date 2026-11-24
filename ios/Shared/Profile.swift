import Foundation

enum Transport: String, Codable {
    case direct, srtp

    var title: String { self == .direct ? "Direct WireGuard" : "VK TURN · SRTP" }
}

struct Profile: Codable {
    var name = ""
    var address = ""
    var privateKey = ""
    var peerPublicKey = ""
    var presharedKey: String?
    var endpoint = ""
    var allowedIPs = "0.0.0.0/0"
    var dns: String?
    var transport = Transport.direct
    var vkLink: String?

    func coreJSON() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let json = String(data: data, encoding: .utf8),
              json.withCString({ vkt_validate($0) }) == 1 else { throw MobileError.invalidProfile }
        return json
    }

    static func importLink(_ url: String) throws -> Profile {
        guard !url.utf8.contains(0),
              let value = url.withCString({ vkt_import($0) }) else { throw MobileError.invalidLink }
        defer { vkt_string_free(value) }
        return try JSONDecoder().decode(Profile.self, from: Data(String(cString: value).utf8))
    }

    func normalized() -> Profile {
        var result = self
        func trim(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        result.name = trim(name)
        result.address = trim(address)
        result.privateKey = trim(privateKey)
        result.peerPublicKey = trim(peerPublicKey)
        result.endpoint = trim(endpoint)
        result.allowedIPs = trim(allowedIPs)
        result.presharedKey = presharedKey.map(trim).flatMap { $0.isEmpty ? nil : $0 }
        result.dns = dns.map(trim).flatMap { $0.isEmpty ? nil : $0 }
        return result
    }
}

enum MobileError: Int, LocalizedError, CustomNSError {
    case invalidProfile = 1, invalidLink, secureStorage, unavailableTransport
    case invalidConfiguration, socket, handshakeTimeout, networkSettings, cancelled, busy

    static var errorDomain: String { "org.ganzzis.vkturn.mobile" }
    var errorCode: Int { rawValue }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? "Tunnel error."] }

    var errorDescription: String? {
        switch self {
        case .invalidProfile: return "Check the keys, IPv4 fields, and endpoint."
        case .invalidLink: return "This VK TURN connection link is invalid or uses an unsupported mode."
        case .secureStorage: return "Secure profile storage is unavailable. Check the signing and Keychain group."
        case .unavailableTransport: return "VK TURN SRTP is not available in this build."
        case .invalidConfiguration: return "The tunnel configuration is unavailable."
        case .socket: return "The tunnel UDP session failed."
        case .handshakeTimeout: return "The WireGuard peer did not complete a handshake."
        case .networkSettings: return "iOS rejected the tunnel network settings."
        case .cancelled: return "Tunnel startup was cancelled."
        case .busy: return "Disconnect the current tunnel first."
        }
    }
}

struct ProfileSummary: Codable, Identifiable {
    let id: UUID
    var name: String
    var transport: Transport
}

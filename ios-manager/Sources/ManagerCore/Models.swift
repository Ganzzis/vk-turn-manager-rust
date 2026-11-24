import Foundation
import Crypto

public struct Server: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name = ""
    public var host = ""
    public var port = 22
    public var user = "root"
    public var hostKey: String?

    public init() {}

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65535).contains(port), !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ asciiWord($0) || [46, 45, 58].contains($0) }),
              !user.isEmpty, user.utf8.count <= 64,
              user.utf8.allSatisfy({ asciiWord($0) || [45, 95].contains($0) })
        else { throw ManagerError.invalidServer }
    }

    public var defaultEndpoint: String {
        (host.contains(":") ? "[\(host)]" : host) + ":56004"
    }
}

private func asciiWord(_ n: UInt8) -> Bool {
    (48...57).contains(n) || (65...90).contains(n) || (97...122).contains(n)
}

public struct Credentials: Codable, Sendable {
    public enum Method: String, Codable, CaseIterable, Sendable {
        case password, key
    }
    public var method: Method = .password
    public var password = ""
    public var privateKey = ""
    public var passphrase = ""
    public var sudoPassword = ""

    public init() {}

    public func validate() throws {
        guard ![password, passphrase, sudoPassword].contains(where: {
            $0.utf8.count > 4096 || $0.contains(where: { $0.isNewline || $0 == "\0" })
        }), method == .password ? !password.isEmpty :
            (!privateKey.isEmpty && privateKey.utf8.count <= 64 * 1024)
        else { throw ManagerError.invalidCredentials }
    }

    var elevationPassword: String? {
        if !sudoPassword.isEmpty { return sudoPassword }
        return method == .password ? password : nil
    }
}

public struct HostKey: Identifiable, Equatable, Sendable {
    public var id: String { fingerprint }
    public let fingerprint: String
}

public enum ManagerError: LocalizedError, Equatable {
    case invalidServer, invalidCredentials, badPrivateKey, hostKeyRequired(HostKey), hostKeyChanged
    case ssh, sudo, timeout, unsupported, badReply, bundle, notManaged, invalidClient, invalidInvite
    case remote(Int), privateStorage
    public var errorDescription: String? {
        switch self {
        case .invalidServer: return "Проверьте имя сервера, IP или DNS-имя, порт и логин."
        case .invalidCredentials: return "Заполните данные SSH. Пароли должны быть в одну строку."
        case .badPrivateKey: return "Не удалось прочитать ключ OpenSSH Ed25519. Проверьте формат и пароль ключа."
        case .hostKeyRequired: return "Сверьте отпечаток SSH с консолью провайдера."
        case .hostKeyChanged: return "Ключ SSH изменился. Операция остановлена. Сверьте новый ключ через консоль провайдера."
        case .ssh: return "Ошибка SSH. Проверьте адрес, порт, доступ и разрешённый способ входа."
        case .sudo: return "Сервер требует root или sudo. Проверьте права и пароль sudo."
        case .timeout: return "Сервер не ответил вовремя. Проверьте состояние установки перед повтором."
        case .unsupported: return "Нужна Ubuntu 24.04 или 26.04 на amd64 или arm64."
        case .badReply: return "Соединение прервалось или сервер вернул неожиданный ответ. Обновите статус."
        case .bundle: return "Не удалось подтвердить целостность встроенного серверного пакета."
        case .notManaged: return "Обнаружена другая или неполная установка. Проверьте службы и конфигурацию."
        case .invalidClient: return "Имя клиента должно содержать 1–32 строчные латинские буквы, цифры или дефисы."
        case .invalidInvite: return "Нужна ссылка https://vk.com/call/join/… или https://vk.ru/call/join/…"
        case .remote(let code): return "Операция завершилась с кодом \(code). Обновите статус и проверьте журнал сервера."
        case .privateStorage: return "Не удалось открыть защищённое хранилище Keychain."
        }
    }
}

public enum Installation: String, Sendable {
    case absent, managed, foreign
}

public struct ServerStatus: Sendable {
    public let system: String
    public let architecture: String
    public let installation: Installation
    public let version: String
    public let wireguard: String
    public let srtp: String
    public let nat: String
}

public struct Peer: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let ipv4: String
    public let publicKey: String
    enum CodingKeys: String, CodingKey {
        case name, ipv4, publicKey = "public_key"
    }
}

public struct Connection: Identifiable, Sendable {
    public var id: String { publicKey }
    public let publicKey: String
    public var endpoint: String?
    public var handshake: Date?
    public var received: UInt64 = 0
    public var sent: UInt64 = 0
}

public enum ServiceAction: String, Sendable {
    case start, stop, restart, remove, enableNAT
}

public struct ServerBundle: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    func files(for architecture: String) throws -> [(name: String, data: Data, digest: String)] {
        guard ["amd64", "arm64"].contains(architecture) else { throw ManagerError.unsupported }
        do {
            let sums = try Data(contentsOf: directory.appendingPathComponent("SHA256SUMS"))
            let manifest = String(decoding: sums, as: UTF8.self)
            let files = ["install.sh", "vk-turn-manager-v0.3.0-linux-\(architecture).tar.gz", "server-linux-\(architecture)"]
            return try files.map { name in
                let matches = manifest.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace) }
                    .filter { $0.count == 2 && $0[1] == name }
                guard matches.count == 1 else { throw ManagerError.bundle }
                let data = try Data(contentsOf: directory.appendingPathComponent(name))
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard matches[0][0] == digest else { throw ManagerError.bundle }
                return (name, data, digest)
            } + [("SHA256SUMS", sums, SHA256.hash(data: sums).map { String(format: "%02x", $0) }.joined())]
        } catch { throw ManagerError.bundle }
    }
}

func quote(_ string: String) -> String {
    "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func checkClient(_ name: String) throws {
    guard name.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil,
          !name.contains(where: \.isNewline) else { throw ManagerError.invalidClient }
}

func checkInvite(_ link: String) throws {
    let prefixes = ["https://vk.com/call/join/", "https://vk.ru/call/join/"]
    guard let prefix = prefixes.first(where: { link.hasPrefix($0) }) else { throw ManagerError.invalidInvite }
    let token = link.dropFirst(prefix.count).utf8
    guard (1...512).contains(token.count), token.allSatisfy({ asciiWord($0) || [45, 95].contains($0) })
    else { throw ManagerError.invalidInvite }
}

func checkEndpoint(_ endpoint: String) throws {
    guard endpoint.utf8.count <= 270, let colon = endpoint.lastIndex(of: ":"),
          colon != endpoint.startIndex, let port = UInt16(endpoint[endpoint.index(after: colon)...]), port > 0,
          endpoint[..<colon].utf8.allSatisfy({ asciiWord($0) || [45, 46, 58, 91, 93].contains($0) })
    else { throw ManagerError.invalidServer }
}

import Foundation

/// Bounded, in-memory log. Only locally defined events, counts and exit codes
/// may enter it. Remote strings, identifiers and credentials are never stored.
public final class DiagnosticLog: @unchecked Sendable {
    enum Operation: String {
        case status = "Проверка состояния"
        case install = "Установка сервера"
        case update = "Обновление сервера"
        case clients = "Список клиентов"
        case addClient = "Добавление клиента"
        case removeClient = "Удаление клиента"
        case profile = "Экспорт профиля"
        case connections = "Подключения WireGuard"
        case logs = "Журнал служб"
        case service = "Управление службами"
    }

    enum Event {
        case connect(Credentials.Method), hostUnconfirmed, hostChanged, hostConfirmed, authenticated
        case connectFailed, authenticationFailed, protocolFailed, timeout, sftpFailed
        case operation(Operation), privileges(Bool), privilegeFailed
        case command, streams(Int, Int), stderr(StderrKind), exit(Int)
        case invalidFrame(FrameFault), invalidStatus(Int), legacyManager, invalidClients
        case completed, cancelled, failed, operationError(ManagerError)

        var summary: String {
            switch self {
            case .connect(let method):
                return method == .password ? "Подключение SSH по паролю." : "Подключение SSH по ключу."
            case .hostUnconfirmed: return "SSH-ключ получен. Вход остановлен до подтверждения отпечатка."
            case .hostChanged: return "SSH-ключ отличается от подтверждённого. Вход остановлен."
            case .hostConfirmed: return "Пользователь подтвердил ключ; начинается новое SSH-соединение."
            case .authenticated: return "SSH-ключ подтверждён. Авторизация SSH успешна."
            case .connectFailed: return "Не удалось установить SSH-соединение. Проверьте адрес и порт."
            case .authenticationFailed: return "SSH-ключ хоста проверен, но авторизация не завершилась. Проверьте логин и способ входа."
            case .protocolFailed: return "Транспорт SSH завершился ошибкой при выполнении команды."
            case .timeout: return "Истёк срок ожидания ответа по SSH."
            case .sftpFailed: return "Передача файлов по SFTP не завершилась."
            case .operation(let operation): return "Операция — \(operation.rawValue)."
            case .privileges(let root): return root ? "Удалённая команда выполняется от root." : "Удалённая команда выполняется через sudo."
            case .privilegeFailed: return "Удалённая команда не получила административные права."
            case .command: return "Запущена удалённая команда."
            case .streams(let out, let err): return "Получено stdout: \(out) байт, stderr: \(err) байт."
            case .stderr(let kind): return "Причина по stderr: \(kind.description)."
            case .exit(let code): return "Код завершения удалённой команды: \(code)."
            case .invalidFrame(let fault): return fault.description
            case .invalidStatus(let lines): return "Некорректный ответ проверки состояния. Получено строк: \(lines), ожидалось 6."
            case .legacyManager: return "Найдена управляемая установка. CLI отсутствует в системных каталогах или не сообщает версию."
            case .invalidClients: return "Команда списка клиентов вернула несовместимый JSON."
            case .completed: return "Операция завершена."
            case .cancelled: return "Операция прервана пользователем."
            case .operationError(let error): return error.localizedDescription
            case .failed: return "Операция остановлена. Подробности указаны выше."
            }
        }
    }

    enum StderrKind: Equatable {
        case sudo, permission, missingCommand, invalidOption, other

        static func classify(_ data: Data) -> Self {
            let text = String(decoding: data, as: UTF8.self).lowercased()
            if text.contains("sudo:") || text.contains("sudo-rs:") { return .sudo }
            if text.contains("permission denied") { return .permission }
            if text.contains("command not found") || text.contains("no such file") { return .missingCommand }
            if text.contains("invalid option") { return .invalidOption }
            return .other
        }

        var description: String {
            switch self {
            case .sudo: return "sudo отказал в запуске или сообщил об ошибке"
            case .permission: return "в доступе отказано"
            case .missingCommand: return "команда или файл отсутствует"
            case .invalidOption: return "команда отклонила аргумент или параметр"
            case .other: return "удалённая команда записала сообщение; исходный текст скрыт"
            }
        }
    }

    private let lock = NSLock()
    private var entries: [(Date, String)] = []

    public init() {}

    func record(_ event: Event) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((Date(), event.summary))
        if entries.count > 100 { entries.removeFirst(entries.count - 100) }
    }

    public func markHostConfirmed() { record(.hostConfirmed) }

    public func markCompletion() { record(.completed) }
    public func markCancellation() { record(.cancelled) }
    public func markFailure(_ error: Error) {
        if let error = error as? ManagerError { record(.operationError(error)) }
        else { record(.failed) }
    }

    public func text() -> String {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return snapshot.map { "[\($0.0.ISO8601Format())] \($0.1)" }.joined(separator: "\n")
    }
}

enum FrameFault: Error, Equatable {
    case missingStart, missingEnd, invalidExit, invalidEncoding, outputLimit

    var description: String {
        switch self {
        case .missingStart: return "Нет маркера начала. Удалённая оболочка не запустила команду."
        case .missingEnd: return "Нет маркера завершения. SSH-канал закрылся до конца команды."
        case .invalidExit: return "Маркер завершения содержит неверный код."
        case .invalidEncoding: return "Данные команды не являются корректным UTF-8."
        case .outputLimit: return "Ответ команды превысил допустимый объём."
        }
    }
}

struct CommandReply {
    let stdout: String
    let exit: Int

    static func parse(_ stdout: Data, marker: String) throws -> Self {
        let beginToken = Data("\n\(marker):BEGIN\n".utf8)
        let endToken = Data("\n\(marker):END:".utf8)
        guard let begin = stdout.range(of: beginToken) else { throw FrameFault.missingStart }
        guard let end = stdout.range(of: endToken, in: begin.upperBound..<stdout.endIndex),
              let newline = stdout[end.upperBound...].firstIndex(of: 10) else { throw FrameFault.missingEnd }
        let code = stdout[end.upperBound..<newline]
        guard (1...3).contains(code.count), code.allSatisfy({ (48...57).contains($0) }),
              let exit = Int(String(decoding: code, as: UTF8.self)), exit <= 255
        else { throw FrameFault.invalidExit }
        guard let output = String(data: stdout[begin.upperBound..<end.lowerBound], encoding: .utf8)
        else { throw FrameFault.invalidEncoding }
        return Self(stdout: output, exit: exit)
    }
}

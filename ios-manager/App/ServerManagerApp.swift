import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins
import ManagerCore

@main
struct ServerManagerApp: App {
    @StateObject private var vault = Vault()
    var body: some Scene {
        WindowGroup { ServerList().environmentObject(vault) }
    }
}

private func message(_ error: Error) -> String {
    if let error = error as? ManagerError { return error.localizedDescription }
    return "Операция не выполнена. Проверьте состояние сервера."
}

private struct ServerList: View {
    @EnvironmentObject private var vault: Vault
    @State private var editor: Server?
    @State private var error = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(vault.servers) { server in
                    NavigationLink(value: server.id) {
                        Label {
                            VStack(alignment: .leading) {
                                Text(server.name)
                                Text("\(server.host):\(server.port)").font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "server.rack").foregroundStyle(.tint) }
                    }
                    .swipeActions {
                        Button("Удалить", role: .destructive) {
                            do { try vault.remove(server.id) }
                            catch { self.error = message(error) }
                        }
                        Button("Изменить") { editor = server }.tint(.blue)
                    }
                }
            }
            .overlay {
                if vault.servers.isEmpty {
                    ContentUnavailableView("Нет серверов", systemImage: "server.rack",
                                           description: Text("Добавьте VPS, чтобы установить VK TURN Proxy или управлять сервером."))
                }
            }
            .navigationTitle("Серверы")
            .navigationDestination(for: UUID.self) { id in
                if vault.servers.contains(where: { $0.id == id }) { ServerDetail(id: id) }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Добавить VPS", systemImage: "plus") { editor = Server() }
                        .disabled(vault.loadFailed)
                }
            }
            .sheet(item: $editor) { ServerEditor(server: $0) }
            .onAppear {
                if vault.loadFailed { error = "Не удалось прочитать список серверов." }
            }
            .alert("Серверы", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) {
                Button("Закрыть", role: .cancel) { error = "" }
            } message: { Text(error) }
        }
    }
}

private struct ServerEditor: View {
    @EnvironmentObject private var vault: Vault
    @Environment(\.dismiss) private var dismiss
    @State var server: Server
    @State private var credentials = Credentials()
    @State private var error = ""
    @State private var resetPin = false

    var body: some View {
        NavigationStack {
            Form {
                Section("VPS") {
                    TextField("Название", text: $server.name)
                    TextField("IP-адрес или DNS-имя", text: $server.host).keyboardType(.URL)
                    TextField("SSH-порт", value: $server.port, format: .number.grouping(.never)).keyboardType(.numberPad)
                    TextField("Логин", text: $server.user)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Section("Доступ SSH") {
                    Picker("Способ входа", selection: $credentials.method) {
                        Text("Пароль").tag(Credentials.Method.password)
                        Text("Ключ Ed25519").tag(Credentials.Method.key)
                    }
                    if credentials.method == .password {
                        SecureField("Пароль SSH", text: $credentials.password)
                    } else {
                        Button("Вставить ключ OpenSSH") {
                            if let key = UIPasteboard.general.string { credentials.privateKey = key }
                        }
                        if !credentials.privateKey.isEmpty {
                            Label("Ключ добавлен", systemImage: "key.fill")
                        }
                        SecureField("Пароль ключа (если задан)", text: $credentials.passphrase)
                    }
                    if server.user != "root" {
                        SecureField(credentials.method == .password ? "Другой пароль sudo (при необходимости)" : "Пароль sudo (если требуется)",
                                    text: $credentials.sudoPassword)
                    }
                }
                if let pin = server.hostKey {
                    Section("Отпечаток SSH") {
                        Text(pin).font(.footnote.monospaced())
                        Toggle("Запросить повторную проверку ключа", isOn: $resetPin)
                    }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Доступ к VPS")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Сохранить", action: save) }
            }
            .onAppear {
                if vault.servers.contains(where: { $0.id == server.id }) {
                    do { credentials = try vault.credentials(server.id) }
                    catch { self.error = message(error) }
                }
            }
        }
    }

    private func save() {
        do {
            server.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            server.host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
            server.user = server.user.trimmingCharacters(in: .whitespacesAndNewlines)
            try server.validate()
            try credentials.validate()
            if resetPin || vault.servers.contains(where: { $0.id == server.id && ($0.host != server.host || $0.port != server.port) }) {
                server.hostKey = nil
            }
            if credentials.method == .password {
                credentials.privateKey = ""; credentials.passphrase = ""
            } else { credentials.password = "" }
            try vault.save(server, credentials: credentials)
            dismiss()
        } catch { self.error = message(error) }
    }
}

private struct ServerDetail: View {
    @EnvironmentObject private var vault: Vault
    let id: UUID
    @State private var status: ServerStatus?
    @State private var peers: [Peer] = []
    @State private var connections: [Connection] = []
    @State private var job: Task<Void, Never>?
    @State private var progress = ""
    @State private var dialog: ServerDialog?
    @State private var peerName = ""
    @State private var profilePeer: Peer?
    @State private var sharedLink: SharedLink?
    @State private var journal: Journal?
    @State private var editor: Server?

    private var server: Server? { vault.servers.first { $0.id == id } }
    private var managed: Bool { status?.installation == .managed }
    private var usable: Bool { managed && status?.version != "-" }

    var body: some View {
        List {
            Section("Сервер") {
                if let status {
                    LabeledContent("Система", value: "\(status.system) · \(status.architecture)")
                    LabeledContent("Установка", value: installation(status.installation))
                    if status.installation == .managed {
                        LabeledContent("Версия", value: status.version == "-" ? "CLI не установлен" : status.version)
                    }
                    LabeledContent("WireGuard", value: service(status.wireguard))
                    LabeledContent("DTLS-SRTP", value: service(status.srtp))
                    LabeledContent("IPv4 NAT", value: service(status.nat))
                } else { Text("Обновите состояние, чтобы проверить VPS.").foregroundStyle(.secondary) }
                if job != nil {
                    ProgressView(progress)
                    Button("Прервать", role: .cancel) { job?.cancel() }
                } else {
                    Button("Обновить состояние", systemImage: "arrow.clockwise") { refresh() }
                }
            }
            if status?.installation == .absent {
                Section {
                    Button("Установить", systemImage: "arrow.down.circle.fill") { deploy(update: false) }
                        .buttonStyle(.borderedProminent)
                } footer: { Text("Установит WireGuard, SRTP и IPv4 NAT. Входящий UDP 56004 должен быть разрешён в настройках VPS.") }
            }
            if managed {
                Section("Управление") {
                    Button("Запустить") { change(.start) }
                    Button("Остановить") { confirm("Остановить VPN-службы?") { change(.stop) } }
                    Button("Перезапустить") { confirm("Перезапустить VPN-службы?") { change(.restart) } }
                    Button("Обновить встроенным пакетом") { confirm("Обновить сервер с сохранением клиентов?") { deploy(update: true) } }
                    if usable {
                        Button("Переустановить SRTP") { confirm("Переустановить SRTP с сохранением клиентов?") { deploy(update: true) } }
                        if status?.nat != "active" {
                            Button("Включить IPv4 NAT") { confirm("Включить NAT и IPv4 forwarding?") { change(.enableNAT) } }
                        }
                        Button("Удалить сервер", role: .destructive) {
                            confirm("Удалить управляемые службы и рабочий конфиг?") { change(.remove) }
                        }
                    }
                }.disabled(job != nil)

                if usable {
                    Section("Клиенты") {
                        Button("Добавить клиента", systemImage: "person.badge.plus") {
                            peerName = ""; dialog = .add
                        }.disabled(status?.wireguard != "active")
                        ForEach(peers) { peer in
                            Button {
                                profilePeer = peer
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(peer.name)
                                    Text(peer.ipv4).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button("Удалить", role: .destructive) {
                                    confirm("Отозвать доступ клиента \(peer.name)?") {
                                        run("Удаление клиента") { manager in
                                            try await manager.changePeer(peer.name, remove: true)
                                            try await load(manager)
                                        }
                                    }
                                }
                            }
                        }
                    }.disabled(job != nil)
                }
                Section("Подключения") {
                    if connections.isEmpty { Text("Нет данных о пирах.").foregroundStyle(.secondary) }
                    ForEach(connections) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(peers.first(where: { $0.publicKey == item.publicKey })?.name ?? String(item.publicKey.prefix(16)))
                                .font(.headline)
                            if let endpoint = item.endpoint { Text(endpoint).font(.subheadline) }
                            if let handshake = item.handshake {
                                LabeledContent("Рукопожатие", value: handshake.formatted(date: .abbreviated, time: .standard))
                            } else { Text("Рукопожатий пока нет.").foregroundStyle(.secondary) }
                            Text("Принято \(bytes(item.received)) · Отправлено \(bytes(item.sent))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Последние записи журнала", systemImage: "doc.text") {
                        run("Чтение журнала") { journal = Journal(text: try await $0.logs()) }
                    }.disabled(job != nil)
                }
            }
        }
        .navigationTitle(server?.name ?? "Сервер")
        .toolbar {
            if let server {
                ToolbarItem(placement: .primaryAction) {
                    Button("Изменить доступ", systemImage: "gearshape") { editor = server }.disabled(job != nil)
                }
            }
        }
        .task { if status == nil { refresh() } }
        .refreshable { if job == nil { refresh(); await job?.value } }
        .onDisappear { job?.cancel() }
        .sheet(item: $editor, onDismiss: { refresh() }) { ServerEditor(server: $0) }
        .sheet(item: $profilePeer) { peer in
            ExportSheet(peer: peer, endpoint: server?.defaultEndpoint ?? "") { endpoint, invite in
                profilePeer = nil
                run("Создание ссылки импорта") { manager in
                    sharedLink = SharedLink(value: try await manager.profile(peer.name, endpoint: endpoint, invite: invite))
                }
            }
        }
        .sheet(item: $sharedLink) { ImportCard(link: $0.value) }
        .sheet(item: $journal) { journal in
            NavigationStack {
                ScrollView { Text(journal.text).font(.footnote.monospaced()).textSelection(.enabled).padding() }
                    .navigationTitle("Журнал служб")
                    .toolbar { Button("Готово") { self.journal = nil } }
            }
        }
        .alert(dialog?.title ?? "Сервер",
               isPresented: Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } }),
               presenting: dialog) { dialog in
            switch dialog {
            case .add:
                TextField("Например, phone", text: $peerName).textInputAutocapitalization(.never)
                Button("Отмена", role: .cancel) {}
                Button("Добавить") {
                    let name = peerName
                    run("Добавление клиента") { manager in
                        try await manager.changePeer(name)
                        try await load(manager)
                    }
                }
            case .confirm(_, let action):
                Button("Подтвердить", role: .destructive, action: action)
                Button("Отмена", role: .cancel) {}
            case .trust(let key):
                Button("Отпечаток совпадает") { trust(key) }
                Button("Отмена", role: .cancel) {}
            case .failure:
                Button("Закрыть", role: .cancel) {}
            }
        } message: { dialog in
            switch dialog {
            case .trust(let key): Text("Сверьте с консолью провайдера.\n\n\(key.fingerprint)")
            case .failure(let error): Text(error)
            default: EmptyView()
            }
        }
    }

    private func trust(_ key: HostKey) {
        guard var stored = server else { return }
        do {
            stored.hostKey = key.fingerprint
            try vault.save(stored, credentials: vault.credentials(id))
            refresh()
        } catch { dialog = .failure(message(error)) }
    }

    private func run(_ title: String, operation: @escaping @MainActor (Manager) async throws -> Void) {
        guard job == nil, let server else { return }
        progress = title
        job = Task { @MainActor in
            defer { job = nil }
            do { try await operation(Manager(server: server, credentials: vault.credentials(id))) }
            catch ManagerError.hostKeyRequired(let key) { dialog = .trust(key) }
            catch is CancellationError { progress = ""; status = nil }
            catch { dialog = .failure(message(error)) }
        }
    }

    private func load(_ manager: Manager) async throws {
        let latest = try await manager.status()
        status = latest
        peers = []
        connections = []
        guard latest.installation == .managed, latest.version != "-" else { return }
        peers = try await manager.peers()
        if latest.wireguard == "active" { connections = try await manager.connections() }
    }

    private func refresh() { run("Чтение состояния", operation: load) }

    private func deploy(update: Bool) {
        run(update ? "Подготовка обновления" : "Подготовка установки") { manager in
            guard let resources = Bundle.main.resourceURL else { throw ManagerError.bundle }
            try await manager.install(ServerBundle(directory: resources.appendingPathComponent("ServerBundle")),
                                      update: update) { stage in
                await MainActor.run { progress = stage }
            }
            try await load(manager)
        }
    }

    private func change(_ action: ServiceAction) {
        run("Управление службами") { manager in
            try await manager.changeService(action)
            try await load(manager)
        }
    }

    private func confirm(_ title: String, _ action: @escaping () -> Void) {
        dialog = .confirm(title, action)
    }

    private func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .memory)
    }

    private func installation(_ value: Installation) -> String {
        switch value { case .absent: return "Не установлен"; case .managed: return "Управляемая"; case .foreign: return "Сторонняя или неполная" }
    }

    private func service(_ value: String) -> String {
        switch value { case "active": return "Работает"; case "inactive": return "Остановлена"; case "failed": return "Ошибка"; default: return value }
    }
}

private enum ServerDialog {
    case add
    case confirm(String, () -> Void)
    case trust(HostKey)
    case failure(String)

    var title: String {
        switch self {
        case .add: return "Добавить клиента"
        case .confirm(let title, _): return title
        case .trust: return "Проверка ключа SSH"
        case .failure: return "Сервер"
        }
    }
}

private struct Journal: Identifiable {
    let id = UUID()
    let text: String
}

private struct SharedLink: Identifiable {
    let id = UUID()
    let value: String
}

private struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let peer: Peer
    @State var endpoint: String
    @State private var invite = ""
    let submit: (String, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Клиент \(peer.name)") {
                    TextField("Публичный SRTP-адрес и порт", text: $endpoint)
                    SecureField("Приглашение VK Calls", text: $invite)
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Ссылка и QR-код содержат приватный ключ клиента. Передавайте их только получателю.")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Профиль VK TURN")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        submit(endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                               invite.trimmingCharacters(in: .whitespacesAndNewlines))
                    }.disabled(endpoint.isEmpty || invite.isEmpty)
                }
            }
        }
    }
}

private struct ImportCard: View {
    @Environment(\.dismiss) private var dismiss
    let link: String
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let qr = qrCode {
                        Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                            .frame(maxWidth: 280).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 20))
                            .accessibilityLabel("QR-код для импорта VPN-профиля")
                    }
                    Text("Импортируйте профиль в оригинальном VK TURN Proxy. Ссылка содержит приватный ключ.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(copied ? "Скопировано" : "Скопировать ссылку", systemImage: "document.on.document") {
                        UIPasteboard.general.setItems([["public.utf8-plain-text": link]], options: [
                            .localOnly: true, .expirationDate: Date().addingTimeInterval(120)
                        ])
                        copied = true
                    }.buttonStyle(.borderedProminent)
                    ShareLink(item: link) { Label("Поделиться ссылкой", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                }.padding()
            }
            .navigationTitle("Ссылка импорта")
            .toolbar { Button("Готово") { dismiss() } }
        }
    }

    private var qrCode: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8)
        filter.correctionLevel = "L"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let pixels = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: pixels)
    }
}

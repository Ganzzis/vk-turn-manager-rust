import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins
import ManagerCore

@main
struct ServerManagerApp: App {
    @StateObject private var vault = Vault()
    var body: some Scene {
        WindowGroup {
                #if DEBUG
                if let screen = ScreenshotScreen.requested {
                    screen.environmentObject(vault).tint(Interface.accent)
                        .preferredColorScheme(ScreenshotScreen.colorScheme)
                } else {
                    ServerList().environmentObject(vault).tint(Interface.accent)
                }
                #else
                ServerList().environmentObject(vault).tint(Interface.accent)
                #endif
            }
    }
}

private func message(_ error: Error) -> String {
    if let error = error as? ManagerError { return error.localizedDescription }
    return "Операция не выполнена. Проверьте состояние сервера."
}

struct ServerList: View {
    @EnvironmentObject private var vault: Vault
    #if DEBUG
    var sampleServers: [Server]? = nil
    #endif
    @State private var editor: Server?
    @State private var error = ""

    private var visibleServers: [Server] {
        #if DEBUG
        if let sampleServers { return sampleServers }
        #endif
        return vault.servers
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visibleServers) { server in
                    NavigationLink(value: server.id) {
                        ServerRow(server: server)
                    }
                    .panel(inset: 12)
                    .dashboardRow()
                    .accessibilityIdentifier("server-\(server.host)")
                    .swipeActions {
                        Button("Забыть VPS", role: .destructive) {
                            do { try vault.remove(server.id) }
                            catch { self.error = message(error) }
                        }
                        Button("Изменить") { editor = server }.tint(.blue)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Interface.background)
            .overlay {
                if visibleServers.isEmpty {
                    ContentUnavailableView {
                        Label("Нет серверов", systemImage: "server.rack")
                    } description: {
                        Text("Добавьте VPS, чтобы установить VK TURN Proxy или управлять существующей установкой.")
                    } actions: {
                        Button("Добавить первый VPS", systemImage: "plus") { editor = Server() }
                            .primaryControl()
                            .disabled(vault.loadFailed)
                    }
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

struct ServerEditor: View {
    @EnvironmentObject private var vault: Vault
    @Environment(\.dismiss) private var dismiss
    @State var server: Server
    @State private var credentials = Credentials()
    @State private var error = ""
    @State private var resetPin = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 13) {
                        PanelHeading(title: "Сервер", symbol: "server.rack")
                        FieldLabel(title: "Название") { TextField("Мой VPS", text: $server.name) }
                        FieldLabel(title: "IP-адрес или DNS-имя") {
                            TextField("server.example", text: $server.host).keyboardType(.URL)
                        }
                        FieldLabel(title: "SSH-порт") {
                            TextField("22", value: $server.port, format: .number.grouping(.never)).keyboardType(.numberPad)
                        }
                        FieldLabel(title: "Логин") { TextField("root", text: $server.user) }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .panel()

                    VStack(alignment: .leading, spacing: 13) {
                        PanelHeading(title: "Авторизация SSH", symbol: "lock.shield")
                        Picker("Способ входа", selection: $credentials.method) {
                            Text("Пароль").tag(Credentials.Method.password)
                            Text("Ключ Ed25519").tag(Credentials.Method.key)
                        }.pickerStyle(.segmented)
                        if credentials.method == .password {
                            FieldLabel(title: "Пароль SSH") {
                                SecureField("Введите пароль", text: $credentials.password)
                            }
                        } else {
                            Button("Вставить ключ OpenSSH", systemImage: "key") {
                                if let key = UIPasteboard.general.string { credentials.privateKey = key }
                            }.secondaryControl()
                            if !credentials.privateKey.isEmpty {
                                Label("Ключ добавлен", systemImage: "checkmark.circle")
                            }
                            FieldLabel(title: "Пароль ключа (если задан)") {
                                SecureField("Пароль ключа", text: $credentials.passphrase)
                            }
                        }
                        if server.user != "root" {
                            FieldLabel(title: credentials.method == .password
                                       ? "Другой пароль sudo (при необходимости)" : "Пароль sudo (если требуется)") {
                                SecureField("Пароль sudo", text: $credentials.sudoPassword)
                            }
                        }
                    }.panel()

                    if let pin = server.hostKey {
                        VStack(alignment: .leading, spacing: 12) {
                            PanelHeading(title: "Отпечаток SSH", symbol: "checkmark.shield")
                            Text(pin).font(.footnote.monospaced()).textSelection(.enabled)
                            Toggle("Запросить повторную проверку ключа", isOn: $resetPin)
                        }.panel()
                    }
                    if !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red).panel().accessibilityIdentifier("save-error")
                    }
                }.padding(16)
            }
            .background(Interface.background)
            .scrollDismissesKeyboard(.interactively)
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

struct ServerDetail: View {
    @EnvironmentObject private var vault: Vault
    let id: UUID
    #if DEBUG
    var sampleServer: Server? = nil
    #endif
    @State private var status: ServerStatus?
    @State private var statusCurrent = false
    @State private var checkedAt: Date?
    @State private var peers: [Peer] = []
    @State private var connections: [Connection] = []
    @State private var job: Task<Void, Never>?
    @State private var progress = ""
    @State private var dialog: ServerDialog?
    @State private var peerName = ""
    @State private var profilePeer: Peer?
    @State private var sharedLink: SharedLink?
    @State private var journal: Journal?
    @State private var diagnostics = DiagnosticLog()
    @State private var diagnosticSheet: Journal?
    @State private var editor: Server?

    private var server: Server? {
        #if DEBUG
        if let sampleServer { return sampleServer }
        #endif
        return vault.servers.first { $0.id == id }
    }

    private var isSample: Bool {
        #if DEBUG
        return sampleServer != nil
        #else
        return false
        #endif
    }

    private var managed: Bool { isSample || status?.installation == .managed }
    private var usable: Bool { managed && status?.version != "-" }
    private var canAddClient: Bool { isSample || status?.wireguard == "active" }

    var body: some View {
        List {
            Section {
                overview.panel().dashboardRow()
                if job != nil {
                    HStack {
                        ProgressView(progress)
                        Spacer()
                        Button("Прервать", role: .cancel) { job?.cancel() }.secondaryControl()
                    }.panel().dashboardRow()
                } else {
                    Button("Обновить состояние", systemImage: "arrow.clockwise") { refresh() }
                        .secondaryControl().dashboardRow()
                }
            }
            if status?.installation == .absent {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        PanelHeading(title: "Установка", symbol: "arrow.down.circle")
                        Text("Установит WireGuard, SRTP и IPv4 NAT. Разрешите входящий UDP 56004.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        installButton.primaryControl()
                    }.panel().dashboardRow()
                }
            }
            if managed {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        PanelHeading(title: "Управление службами", symbol: "switch.2")
                        ViewThatFits(in: .horizontal) {
                            HStack { serviceControls }
                            VStack(alignment: .leading, spacing: 8) { serviceControls }
                        }
                    }.panel().dashboardRow()
                }.disabled(job != nil)

                if usable {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            PanelHeading(title: "Клиенты", symbol: "person.2")
                            Button("Добавить клиента", systemImage: "person.badge.plus") {
                                peerName = ""; dialog = .add
                            }.primaryControl().disabled(!canAddClient)
                            if peers.isEmpty && !isSample {
                                Text("Клиентов пока нет.").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.panel().dashboardRow()
                        #if DEBUG
                        if isSample {
                            sampleClient.panel().dashboardRow()
                        }
                        #endif
                        ForEach(peers) { peer in
                            VStack(alignment: .leading, spacing: 9) {
                                clientCard(peer: peer, item: connections.first { $0.publicKey == peer.publicKey })
                                Button("Экспорт и QR-код", systemImage: "qrcode") { profilePeer = peer }
                                    .secondaryControl()
                            }
                            .panel()
                            .dashboardRow()
                            .swipeActions {
                                Button("Удалить", role: .destructive) { removeClient(peer) }
                            }
                            .accessibilityAction(named: Text("Удалить клиента")) { removeClient(peer) }
                        }
                    }.disabled(job != nil)
                }
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        PanelHeading(title: "Подключения", symbol: "point.3.connected.trianglepath.dotted")
                        if isSample {
                            Text("Рукопожатия и трафик указаны в карточках клиентов.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else if connections.isEmpty {
                            Text("Нет данных о пирах.").font(.subheadline).foregroundStyle(.secondary)
                        } else if unlistedConnections.isEmpty {
                            Text("Рукопожатия и трафик указаны в карточках клиентов.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.panel().dashboardRow()
                    ForEach(unlistedConnections) { item in
                        clientCard(peer: nil, item: item).panel().dashboardRow()
                    }
                }
                Section {
                    VStack(alignment: .leading, spacing: 9) {
                        PanelHeading(title: "Обслуживание", symbol: "wrench.and.screwdriver")
                        Button("Обновить встроенным пакетом", systemImage: "arrow.down.circle") {
                            confirm("Обновить сервер с сохранением клиентов?") { deploy(update: true) }
                        }
                        if usable {
                            Button("Переустановить SRTP", systemImage: "arrow.trianglehead.clockwise") {
                                confirm("Переустановить SRTP с сохранением клиентов?") { deploy(update: true) }
                            }
                            if status?.nat != "active" {
                                Button("Включить IPv4 NAT", systemImage: "network") {
                                    confirm("Включить NAT и IPv4 forwarding?") { change(.enableNAT) }
                                }
                            }
                            Button(role: .destructive) {
                                confirm("Удалить управляемые службы и рабочий конфиг?") { change(.remove) }
                            } label: { Label("Удалить сервер", systemImage: "trash") }
                        }
                    }.buttonStyle(.borderless).panel().dashboardRow()
                }.disabled(job != nil)
            }
            Section {
                VStack(alignment: .leading, spacing: 9) {
                    PanelHeading(title: "Диагностика", symbol: "waveform.path.ecg")
                    Button("Диагностика SSH", systemImage: "stethoscope") {
                        diagnosticSheet = Journal(text: diagnostics.text())
                    }
                    if managed {
                        Button("Последние записи журнала", systemImage: "doc.text") {
                            run("Чтение журнала") { journal = Journal(text: try await $0.logs()) }
                        }.disabled(job != nil)
                    }
                }.buttonStyle(.borderless).panel().dashboardRow()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Interface.background)
        .navigationTitle("Обзор VPS")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let server {
                ToolbarItem(placement: .primaryAction) {
                    Button("Изменить доступ", systemImage: "gearshape") { editor = server }.disabled(job != nil)
                }
            }
        }
        .task { if status == nil && !isSample { refresh() } }
        .refreshable { if job == nil { refresh(); await job?.value } }
        .onDisappear { job?.cancel() }
        .sheet(item: $editor, onDismiss: { status = nil; refresh() }) { ServerEditor(server: $0) }
        .sheet(item: $profilePeer) { peer in
            ExportSheet(peer: peer, endpoint: server?.defaultEndpoint ?? "") { endpoint, invite in
                profilePeer = nil
                run("Создание ссылки импорта") { manager in
                    sharedLink = SharedLink(value: try await manager.profile(peer.name, endpoint: endpoint, invite: invite))
                }
            }
        }
        .sheet(item: $sharedLink) { ImportCard(link: $0.value) }
        .sheet(item: $diagnosticSheet) { report in
            NavigationStack {
                ScrollView {
                    Text(report.text.isEmpty ? "Запустите обновление статуса, чтобы собрать диагностику." : report.text)
                        .font(.footnote.monospaced()).textSelection(.enabled).padding()
                }
                .navigationTitle("Диагностика SSH")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Готово") { diagnosticSheet = nil }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Копировать", systemImage: "document.on.document") {
                            UIPasteboard.general.setItems([["public.utf8-plain-text": report.text]], options: [.localOnly: true])
                        }.disabled(report.text.isEmpty)
                    }
                }
            }
        }
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

    @ViewBuilder private var overview: some View {
        #if DEBUG
        if isSample {
            ServerOverview(name: server?.name ?? "Сервер", address: "192.0.2.10:22",
                           system: "Ubuntu 26.04", architecture: "amd64", backend: "0.3.0",
                           installation: "Управляемая", wireguard: "active", srtp: "active",
                           nat: "inactive", freshness: "Проверено: 25 ноября, 14:28")
        } else {
            currentOverview
        }
        #else
        currentOverview
        #endif
    }

    #if DEBUG
    private var sampleClient: some View {
        VStack(alignment: .leading, spacing: 9) {
            ClientCard(name: "iphone", address: "10.20.0.2/32", endpoint: nil,
                       handshake: "25 нояб., 14:22:18", traffic: "Принято 24 МБ · Отправлено 81 МБ")
            Button("Экспорт и QR-код", systemImage: "qrcode") {
                profilePeer = ScreenshotScreen.peer
            }.secondaryControl()
        }.accessibilityIdentifier("sample-client")
    }
    #endif

    private var currentOverview: some View {
        ServerOverview(
            name: server?.name ?? "Сервер",
            address: server.map { "\($0.host):\($0.port)" } ?? "",
            system: status?.system, architecture: status?.architecture,
            backend: managed ? status.map { managerVersion($0.version) } : nil,
            installation: status.map { installation($0.installation) },
            wireguard: job == nil && statusCurrent ? status?.wireguard : nil,
            srtp: job == nil && statusCurrent ? status?.srtp : nil,
            nat: job == nil && statusCurrent ? status?.nat : nil,
            freshness: freshness
        )
    }

    private var freshness: String {
        if job != nil { return "Выполняется операция" }
        guard let checkedAt, status != nil else { return "Статус не проверен. Обновите состояние VPS." }
        let time = checkedAt.formatted(date: .abbreviated, time: .shortened)
        return statusCurrent ? "Проверено: \(time)" : "Последняя проверка: \(time). Статус не подтверждён."
    }

    private var serviceControls: some View {
        Group {
            Button("Запустить", systemImage: "play.fill") { change(.start) }
                .secondaryControl()
            Button("Остановить", systemImage: "stop.fill") {
                confirm("Остановить VPN-службы?") { change(.stop) }
            }.secondaryControl()
            Button("Перезапустить", systemImage: "arrow.clockwise") {
                confirm("Перезапустить VPN-службы?") { change(.restart) }
            }.secondaryControl()
        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var unlistedConnections: [Connection] {
        connections.filter { item in !peers.contains { $0.publicKey == item.publicKey } }
    }

    private func clientCard(peer: Peer?, item: Connection?) -> some View {
        let telemetry = statusCurrent && job == nil ? item : nil
        return ClientCard(name: peer?.name ?? String(item?.publicKey.prefix(16) ?? ""),
                   address: peer?.ipv4, endpoint: telemetry?.endpoint,
                   handshake: telemetry?.handshake?.formatted(date: .abbreviated, time: .standard),
                   traffic: telemetry.map { "Принято \(bytes($0.received)) · Отправлено \(bytes($0.sent))" })
    }

    private func removeClient(_ peer: Peer) {
        confirm("Отозвать доступ клиента \(peer.name)?") {
            run("Удаление клиента") { manager in
                try await manager.changePeer(peer.name, remove: true)
                try await load(manager)
            }
        }
    }

    private func trust(_ key: HostKey) {
        guard var stored = server else { return }
        do {
            stored.hostKey = key.fingerprint
            try vault.save(stored, credentials: vault.credentials(id))
            diagnostics.markHostConfirmed()
            refresh()
        } catch { dialog = .failure(message(error)) }
    }

    private var installButton: some View {
        Button("Установить", systemImage: "arrow.down.circle.fill") { deploy(update: false) }
            .disabled(job != nil)
    }

    private func run(_ title: String, operation: @escaping @MainActor (Manager) async throws -> Void) {
        guard job == nil, !isSample, let server else { return }
        progress = title
        job = Task { @MainActor in
            defer { job = nil }
            do {
                try await operation(Manager(server: server, credentials: vault.credentials(id), diagnostics: diagnostics))
                diagnostics.markCompletion()
            } catch ManagerError.hostKeyRequired(let key) {
                statusCurrent = false
                dialog = .trust(key)
            } catch is CancellationError {
                diagnostics.markCancellation()
                progress = ""; status = nil
                statusCurrent = false
            } catch {
                diagnostics.markFailure(error)
                statusCurrent = false
                dialog = .failure(message(error))
            }
        }
    }

    private func load(_ manager: Manager) async throws {
        let latest = try await manager.status()
        status = latest
        checkedAt = Date()
        statusCurrent = true
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

    private func managerVersion(_ version: String) -> String {
        switch version {
        case "-": return "CLI не найден"
        case "unknown": return "CLI найден, версия неизвестна"
        default: return version.replacingOccurrences(of: "vk-turn-manager ", with: "", options: .anchored)
        }
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

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let peer: Peer
    @State var endpoint: String
    @State private var invite = ""
    let submit: (String, String) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 13) {
                        PanelHeading(title: "Клиент \(peer.name)", symbol: "person.crop.circle")
                        FieldLabel(title: "Публичный SRTP-адрес и порт") {
                            TextField("server.example:56004", text: $endpoint)
                        }
                        FieldLabel(title: "Приглашение VK Calls") {
                            SecureField("Вставьте ссылку", text: $invite)
                        }
                    }.textInputAutocapitalization(.never).autocorrectionDisabled().panel()
                    Label("Ссылка и QR-код содержат приватный ключ клиента. Передавайте их только получателю.",
                          systemImage: "lock.shield").font(.subheadline).foregroundStyle(.secondary).panel()
                }.padding(16)
            }.background(Interface.background)
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

struct ImportCard: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { copied = true }
                    }.primaryControl()
                    ShareLink(item: link) { Label("Поделиться ссылкой", systemImage: "square.and.arrow.up") }
                        .secondaryControl()
                }.padding(18).panel().padding(16)
            }
            .background(Interface.background)
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

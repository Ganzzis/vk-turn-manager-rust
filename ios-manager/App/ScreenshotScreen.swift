#if DEBUG
import SwiftUI
import ManagerCore

enum ScreenshotScreen: String, View {
    case empty, servers, dashboard, clients, settings, export, qr, diagnostics

    static var requested: Self? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "--capture-ui"), arguments.indices.contains(i + 1) else { return nil }
        return Self(rawValue: arguments[i + 1])
    }

    static var colorScheme: ColorScheme {
        ProcessInfo.processInfo.arguments.contains("--dark-screenshot") ? .dark : .light
    }

    private static var sample: Server {
        var server = Server()
        server.name = "Хельсинки"
        server.host = "192.0.2.10"
        server.user = "root"
        server.hostKey = "SHA256:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq"
        return server
    }

    static var peer: Peer {
        // The fixture mirrors the export fields and never comes from a VPS.
        try! JSONDecoder().decode(Peer.self, from: Data(
            #"{"name":"iphone","ipv4":"10.20.0.2/32","public_key":"screenshot-fixture"}"#.utf8))
    }

    var body: some View {
        let server = Self.sample
        switch self {
        case .empty:
            ServerList(sampleServers: [])
        case .servers:
            ServerList(sampleServers: [server, secondary])
        case .dashboard, .clients, .diagnostics:
            NavigationStack { ServerDetail(id: server.id, sampleServer: server) }
        case .settings:
            ServerEditor(server: server)
        case .export:
            ExportSheet(peer: Self.peer, endpoint: "192.0.2.10:56004") { _, _ in }
        case .qr:
            ImportCard(link: "vkturnproxy://import?data=illustration-only")
        }
    }

    private var secondary: Server {
        var server = Server()
        server.name = "Франкфурт"
        server.host = "198.51.100.24"
        server.port = 2222
        return server
    }
}
#endif

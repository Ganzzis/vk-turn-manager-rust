import SwiftUI
import UIKit
import ManagerCore

enum Interface {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.42, green: 0.66, blue: 1, alpha: 1)
            : UIColor(red: 0.13, green: 0.34, blue: 0.73, alpha: 1)
    })
}

extension View {
    func panel(inset: CGFloat = 16) -> some View {
        padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Interface.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    func dashboardRow() -> some View {
        listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    @ViewBuilder func primaryControl() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder func secondaryControl() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

struct SymbolTile: View {
    let symbol: String
    var color: Color = Interface.accent

    var body: some View {
        Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .frame(minWidth: 42, minHeight: 42)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

struct FieldLabel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.semibold)).accessibilityHidden(true)
            content
                .accessibilityLabel(title)
                .padding(12)
                .background(Interface.background, in: RoundedRectangle(cornerRadius: 11))
        }
    }
}

struct PanelHeading: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ServiceBadge: View {
    let title: String
    let value: String?

    private var appearance: (String, String, Color) {
        switch value {
        case "active": return ("Работает", "checkmark.circle.fill", .green)
        case "inactive": return ("Остановлен", "stop.circle.fill", .red)
        case "failed": return ("Ошибка", "exclamationmark.circle.fill", .red)
        default: return ("Неизвестно", "minus.circle.fill", .secondary)
        }
    }

    var body: some View {
        let (label, symbol, color) = appearance
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
                Text(label).foregroundStyle(.secondary)
            }.font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Interface.background, in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
    }
}

struct ServerRow: View {
    let server: Server

    var body: some View {
        HStack(spacing: 13) {
            SymbolTile(symbol: "server.rack")
            VStack(alignment: .leading, spacing: 5) {
                Text(server.name).font(.headline)
                Text("\(server.host):\(server.port)")
                    .font(.subheadline.monospaced()).foregroundStyle(.secondary)
                Label("Статус не проверен", systemImage: "minus.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

struct ServerOverview: View {
    let name: String
    let address: String
    let system: String?
    let architecture: String?
    let backend: String?
    let installation: String?
    let wireguard: String?
    let srtp: String?
    let nat: String?
    let freshness: String

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                SymbolTile(symbol: "server.rack")
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text(address).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                }
            }
            if let system, let architecture {
                Text("\(system) · \(architecture)").font(.subheadline)
            }
            if let installation { Text(installation).font(.subheadline) }
            if let backend { Text("Backend \(backend)").font(.subheadline) }
            Text(freshness).font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 6) { badges }
                VStack(spacing: 6) { badges }
            }
        }
    }

    private var badges: some View {
        Group {
            ServiceBadge(title: "WireGuard", value: wireguard)
            ServiceBadge(title: "DTLS-SRTP", value: srtp)
            ServiceBadge(title: "IPv4 NAT", value: nat)
        }
    }
}

struct ClientCard: View {
    let name: String
    let address: String?
    let endpoint: String?
    let handshake: String?
    let traffic: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                SymbolTile(symbol: "person.crop.circle")
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.headline)
                    if let address { Text(address).font(.subheadline.monospaced()).foregroundStyle(.secondary) }
                }
            }
            if let endpoint {
                Label(endpoint, systemImage: "network").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Label(handshake.map { "Последнее рукопожатие: \($0)" } ?? "Нет данных о рукопожатии",
                  systemImage: "clock").font(.caption).foregroundStyle(.secondary)
            if let traffic {
                Label(traffic, systemImage: "arrow.up.arrow.down").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

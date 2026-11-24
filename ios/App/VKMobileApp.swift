import NetworkExtension
import SwiftUI

@main
struct VKMobileApp: App {
    var body: some Scene {
        WindowGroup { ConnectionsView() }
    }
}

private struct Editor: Identifiable {
    let id = UUID()
    var savedID: UUID?
    var profile: Profile
}

struct ConnectionsView: View {
    @StateObject private var store = ProfileStore()
    @StateObject private var tunnel = TunnelController()
    @State private var editor: Editor?
    @State private var importSheet = false
    @State private var importText = ""
    @State private var alert = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Tunnel") {
                    LabeledContent("Status", value: tunnel.title)
                    if !tunnel.diagnostic.isEmpty {
                        Text(tunnel.diagnostic).foregroundStyle(.secondary)
                    }
                    if tunnel.status == .connected {
                        Button("Refresh diagnostics", action: tunnel.refreshDiagnostics)
                    }
                    if tunnel.busy {
                        Button("Disconnect", action: tunnel.stop).disabled(tunnel.starting)
                    }
                }
                Section("Connections") {
                    if store.summaries.isEmpty {
                        Text("Add a WireGuard peer or import a VK TURN link.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.summaries) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.name).font(.headline)
                            Text(item.transport.title).foregroundStyle(.secondary)
                            if item.transport == .srtp {
                                Text("Transport unavailable in this build.").font(.footnote)
                            } else if tunnel.activeID != item.id {
                                Button("Connect") { connect(item.id) }.disabled(tunnel.busy)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) {
                                do { try store.remove(item.id) } catch { alert = MobileError.secureStorage.localizedDescription }
                            }
                            .disabled(tunnel.busy)
                            Button("Edit") { edit(item.id) }.tint(.blue).disabled(tunnel.busy)
                        }
                    }
                }
            }
            .navigationTitle("Connections")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Add WireGuard", systemImage: "plus") { editor = Editor(profile: Profile()) }
                        Button("Import VK TURN link", systemImage: "square.and.arrow.down") { importSheet = true }
                    } label: {
                        Label("Add connection", systemImage: "plus")
                    }
                }
            }
            .task { do { try await tunnel.load() } catch { alert = "Could not load VPN settings." } }
            .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in tunnel.refresh() }
            .onOpenURL { url in
                if url.scheme?.lowercased() == "vkturnproxy" { importLink(url.absoluteString) }
            }
            .sheet(item: $editor) { selected in
                ProfileEditor(profile: selected.profile) { profile in
                    try store.save(profile, id: selected.savedID)
                    editor = nil
                }
            }
            .sheet(isPresented: $importSheet, onDismiss: { importText = "" }) {
                NavigationStack {
                    Form {
                        SecureField("vkturnproxy:// link", text: $importText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .navigationTitle("Import link")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { importSheet = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Import") {
                                let value = importText
                                importSheet = false
                                importLink(value)
                            }
                        }
                    }
                }
            }
            .alert("Connection", isPresented: Binding(get: { !alert.isEmpty }, set: { if !$0 { alert = "" } })) {
                Button("OK", role: .cancel) { alert = "" }
            } message: { Text(alert) }
        }
    }

    private func edit(_ id: UUID) {
        do { editor = Editor(savedID: id, profile: try store.profile(id)) }
        catch { alert = MobileError.secureStorage.localizedDescription }
    }

    private func importLink(_ link: String) {
        do {
            let profile = try Profile.importLink(link)
            try store.save(profile, id: nil)
        }
        catch let error as MobileError { alert = error.localizedDescription }
        catch { alert = MobileError.invalidLink.localizedDescription }
    }

    private func connect(_ id: UUID) {
        Task {
            do { try await tunnel.connect(id, profile: store.profile(id)) }
            catch let error as MobileError { alert = error.localizedDescription }
            catch { alert = "Could not start the VPN. Check iOS VPN permissions." }
        }
    }
}

private struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: Profile
    @State private var error = ""
    let save: (Profile) throws -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(profile.transport.title) {
                    TextField("Name", text: $profile.name)
                    TextField("IPv4 address/prefix", text: $profile.address)
                    TextField("Endpoint (host:port)", text: $profile.endpoint)
                    TextField("Allowed IPv4 networks", text: $profile.allowedIPs)
                    TextField("DNS (optional)", text: optional($profile.dns))
                }
                Section("Keys") {
                    SecureField("Private key", text: $profile.privateKey)
                    SecureField("Peer public key", text: $profile.peerPublicKey)
                    SecureField("Preshared key (optional)", text: optional($profile.presharedKey))
                }
                if profile.transport == .srtp {
                    Section("VK call") {
                        SecureField("Call join link", text: optional($profile.vkLink))
                        Text("SRTP transport is unavailable in this build.").foregroundStyle(.secondary)
                    }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Connection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try save(profile) }
                        catch let failure as MobileError { error = failure.localizedDescription }
                        catch { error = MobileError.invalidProfile.localizedDescription }
                    }
                }
            }
        }
    }

    private func optional(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gear") }
            SnippetSettingsView().tabItem { Label("Snippets", systemImage: "text.quote") }
        }
        .frame(width: 560)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(StorePaths.storeOverrideKey) private var storeOverride = ""
    @AppStorage(AllmanBinary.overrideKey) private var binaryOverride = ""
    @AppStorage(Notifier.enabledKey) private var notificationsEnabled = true
    @AppStorage(SyncEngine.syncIntervalKey) private var syncInterval = 15
    @State private var addingWithOptions = false
    @State private var proxy = ""
    @State private var captureSalesNav = true

    var body: some View {
        Form {
            Section {
                ForEach(model.sessions) { session in
                    HStack(spacing: 12) {
                        AccountHeader(session: session, size: 40)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            StatusBadge(status: session.engine.status, syncing: session.engine.isSyncing)
                            HStack(spacing: 6) {
                                if session.id != model.current?.id {
                                    Button("Show in Inbox") { model.select(accountId: session.id) }
                                } else {
                                    Text("Shown in Inbox").font(.caption).foregroundStyle(.secondary)
                                }
                                if session.isAuthenticated {
                                    Button("Sign Out") { model.signOut(session) }
                                } else {
                                    Button("Sign In…") { session.engine.login() }
                                        .disabled(session.engine.status == .loggingIn)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
                HStack {
                    Button(model.isAddingAccount ? "Waiting for browser sign-in…" : "Add Account…") { model.addAccount() }
                        .disabled(model.isAddingAccount)
                    Button("Options…") { addingWithOptions = true }
                        .disabled(model.isAddingAccount)
                        .help("Sign in through an HTTP proxy, or skip the Sales Navigator seat capture")
                        .popover(isPresented: $addingWithOptions, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Add account with options").font(.headline)
                                TextField("Proxy host:port[:user:pass] (optional)", text: $proxy).textFieldStyle(.roundedBorder)
                                Text("Saved to the account's config.json; every request for this account goes through it.").font(.caption).foregroundStyle(.secondary)
                                Toggle("Capture Sales Navigator seat (visits /sales/ once)", isOn: $captureSalesNav)
                                HStack {
                                    Spacer()
                                    Button("Sign In…") { addingWithOptions = false; model.addAccount(proxy: proxy, captureSalesNav: captureSalesNav) }
                                        .keyboardShortcut(.defaultAction)
                                }
                            }
                            .padding(14)
                            .frame(width: 380)
                        }
                    Spacer()
                    Text(model.sessions.isEmpty ? "Sign in to LinkedIn to get started." : "Every account syncs and notifies; the inbox shows one at a time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Accounts")
            }

            Section("Store") {
                LabeledContent("Location") {
                    HStack {
                        Text(model.storeURL.path).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([model.storeURL]) }
                    }
                }
                TextField("Override path", text: $storeOverride, prompt: Text("~/.allman"))
                    .onSubmit { model.restart() }
                Text("Leave blank to use ~/.allman (or $ALLMAN_STORE). The same store the allman CLI and TUI use.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("allman CLI") {
                LabeledContent("Binary") {
                    if let b = model.binaryURL {
                        HStack {
                            Text(b.path).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            if AllmanBinary.isEmbedded { Text("bundled").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                        }
                    } else {
                        Text("Not found").foregroundStyle(.orange)
                    }
                }
                HStack {
                    TextField("Override path", text: $binaryOverride, prompt: Text("/usr/local/bin/allman"))
                        .onSubmit { model.restart() }
                    Button("Choose…") { chooseBinary() }
                }
                Text("Install: curl -fsSL https://allman.sh/install.sh | bash").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Section("Behavior") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Notify for new messages", isOn: $notificationsEnabled)
                Toggle("Transcribe voice notes on this Mac", isOn: Binding(get: { model.transcripts.isEnabled }, set: { model.transcripts.isEnabled = $0 }))
                Picker("Background sync every", selection: $syncInterval) {
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("Hour").tag(60)
                }
                .onChange(of: syncInterval) { _, v in model.engine.syncIntervalMinutes = v }
                Text("Live updates arrive instantly over LinkedIn's realtime stream; the periodic sync is a safety net for anything missed while offline.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Apply & Restart Sync") { model.restart() }
                    Spacer()
                    Text("Allman \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        panel.message = "Choose the allman executable"
        if panel.runModal() == .OK, let url = panel.url {
            binaryOverride = url.path
            model.restart()
        }
    }
}

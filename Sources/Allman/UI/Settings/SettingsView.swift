import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case accounts, store, cli, behavior, snippets
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accounts: return "Accounts"
        case .store: return "Store"
        case .cli: return "allman CLI"
        case .behavior: return "Behavior"
        case .snippets: return "Snippets"
        }
    }
    var symbol: String {
        switch self {
        case .accounts: return "person.crop.circle"
        case .store: return "externaldrive"
        case .cli: return "terminal"
        case .behavior: return "slider.horizontal.3"
        case .snippets: return "text.quote"
        }
    }
    var blurb: String {
        switch self {
        case .accounts: return "Every signed-in account syncs and notifies; the messenger shows one at a time."
        case .store: return "Where the allman CLI keeps conversations — shared with the CLI and TUI."
        case .cli: return "The allman binary every write goes through."
        case .behavior: return "Launch, notifications, sync cadence, transcripts."
        case .snippets: return "Saved replies with placeholders, one keystroke away."
        }
    }
}

struct SettingsSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.settingsSection) {
            ForEach(SettingsSection.allCases) { s in Label(s.title, systemImage: s.symbol).tag(s) }
            Section {
                Text("Allman \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(AFont.meta).foregroundStyle(.tertiary)
            }
        }
        .listStyle(.sidebar)
        .contentMargins(.top, 0, for: .scrollContent)
    }
}

struct SettingsDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let section = model.settingsSection
        Group {
            if section == .snippets {
                SnippetSettingsView()
            } else {
                GeneralSettingsView(section: section)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                PageHeader(symbol: section.symbol, title: section.title, line1: section.blurb)
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }
}

/// Legacy single-form settings (used by the inline Settings page, one section at a time).
struct SettingsView: View {
    var body: some View { SettingsDetail() }
}

struct GeneralSettingsView: View {
    var section: SettingsSection = .accounts
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
            if section == .accounts {
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
                    if model.sessions.isEmpty { Text("Sign in to LinkedIn to get started.").font(AFont.meta).foregroundStyle(.secondary) }
                }
            }
            }

            if section == .store {
            Section {
                LabeledContent("Location") {
                    HStack {
                        Text(model.storeURL.path).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([model.storeURL]) }
                    }
                }
                TextField("Override path", text: $storeOverride, prompt: Text("~/.allman"))
                    .onSubmit { model.restart() }
                if StorePaths.overrideIsInvalid {
                    Label("“\(storeOverride)” is not a directory — ignored; using the default store.", systemImage: "exclamationmark.triangle.fill")
                        .font(AFont.meta).foregroundStyle(.orange)
                }
                Text("Leave blank to use ~/.allman (or $ALLMAN_STORE). The same store the allman CLI and TUI use.")
                    .font(AFont.meta).foregroundStyle(.secondary)
            }
            Section {
                let usage = ImageCache.shared.diskUsage()
                LabeledContent("Image cache") {
                    HStack {
                        Text("\(usage.count) pictures · \(ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))").font(AFont.secondary).foregroundStyle(.secondary)
                        Button("Clear") { ImageCache.shared.clearDisk() }.controlSize(.small)
                    }
                }
                Text("Profile pictures and link previews are kept for 30 days in ~/Library/Caches/Allman. Thread media stays in the store under each conversation's media/ folder.")
                    .font(AFont.meta).foregroundStyle(.secondary)
            }
            }

            if section == .cli {
            Section {
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
            }

            if section == .behavior {
            Section {
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
            }

            if section == .store || section == .cli {
            Section {
                HStack {
                    Button("Apply & Restart Sync") { model.restart() }
                    Spacer()
                }
            }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
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

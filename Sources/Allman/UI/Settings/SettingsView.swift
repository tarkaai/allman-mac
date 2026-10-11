import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(StorePaths.storeOverrideKey) private var storeOverride = ""
    @AppStorage(AllmanBinary.overrideKey) private var binaryOverride = ""
    @AppStorage(Notifier.enabledKey) private var notificationsEnabled = true
    @AppStorage(SyncEngine.syncIntervalKey) private var syncInterval = 15

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
        .frame(width: 520)
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

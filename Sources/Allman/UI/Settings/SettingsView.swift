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
            Section("Account") {
                if model.accounts.isEmpty {
                    LabeledContent("LinkedIn account") {
                        Button("Sign in…") { model.engine.login() }
                    }
                } else {
                    Picker("LinkedIn account", selection: Binding(
                        get: { model.account?.slug ?? "" },
                        set: { model.selectAccount($0) }
                    )) {
                        ForEach(model.accounts) { a in Text("\(a.slug == model.account?.slug ? model.accountDisplayName : a.displayName) (@\(a.slug))").tag(a.slug) }
                    }
                    if let a = model.account {
                        LabeledContent("Status", value: a.auth.isAuthenticated ? "Signed in" : "Signed out")
                        Button("Re-authenticate…") { model.engine.login() }
                    }
                }
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

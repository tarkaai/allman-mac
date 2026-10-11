import AppKit
import SwiftUI

/// The one main window. A switcher on the left of the toolbar picks the
/// experience: Messenger (default), Network, Insights or Settings.
struct InboxWindow: View {
    @Environment(AppModel.self) private var model
    @State private var composing = false
    @State private var choosingSyncWindow = false

    var body: some View {
        @Bindable var inbox = model.inbox
        Group {
            switch model.experience {
            case .messenger: messenger
            case .network: NetworkView().toolbar { switcher }
            case .insights: InsightsView(inline: true).toolbar { switcher }
            case .settings:
                ScrollView { SettingsView().frame(maxWidth: .infinity) }
                    .toolbar { switcher }
                    .navigationTitle("Settings")
            }
        }
        .sheet(isPresented: $composing) { ComposeSheet().environment(model) }
        .onReceive(NotificationCenter.default.publisher(for: .allmanCompose)) { _ in model.experience = .messenger; composing = true }
        .onReceive(NotificationCenter.default.publisher(for: .allmanSyncWindow)) { _ in choosingSyncWindow = true }
        .sheet(isPresented: $choosingSyncWindow) { SyncWindowSheet().environment(model) }
        .frame(minWidth: 860, minHeight: 540)
        .background(WindowAccessor { window in
            window.identifier = NSUserInterfaceItemIdentifier("inbox")
            window.tabbingMode = .disallowed
        })
        .overlay(alignment: .bottom) {
            if let toast = inbox.toast {
                HStack(spacing: 10) {
                    Text(toast).font(.callout)
                    if let undo = inbox.undo {
                        Button(undo.title) { undo.action(); inbox.undo = nil; inbox.toast = nil }
                            .buttonStyle(.link).font(.callout.weight(.semibold))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 70)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(for: .seconds(inbox.undo == nil ? 4 : 7))
                    inbox.toast = nil
                    inbox.undo = nil
                }
            }
        }
        .animation(.default, value: inbox.toast)
    }

    private var messenger: some View {
        @Bindable var inbox = model.inbox
        return NavigationSplitView {
            ConversationListView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 460)
                .toolbar { switcher }
        } detail: {
            if let draft = inbox.draft {
                DraftThreadView(recipient: draft)
                    .id(draft.convId)
            } else if let snap = inbox.selected {
                ThreadView(snapshot: snap)
                    .id(snap.record.convId)
            } else if inbox.isLoading {
                ProgressView("Loading conversations…")
            } else if inbox.snapshots.isEmpty {
                ContentUnavailableView {
                    Label("No conversations yet", systemImage: "tray")
                } description: {
                    Text(model.engine.status == .needsLogin ? "Sign in from the menu bar to start syncing." : "The first sync will fill this in.")
                } actions: {
                    if model.engine.status == .needsLogin { Button("Sign in to LinkedIn") { model.engine.login() } }
                }
            } else {
                ContentUnavailableView("Select a conversation", systemImage: "bubble.left.and.bubble.right", description: Text("\(inbox.snapshots.count) conversations · \(inbox.unreadCount) unread"))
            }
        }
        .navigationTitle("")
    }

    private var switcher: some ToolbarContent {
        ToolbarItem(placement: .navigation) { ExperienceSwitcher() }
    }
}

/// Messenger · Network · Insights · Settings, as an icon segmented control.
struct ExperienceSwitcher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("Experience", selection: $model.experience) {
            ForEach(AppModel.Experience.allCases) { e in
                Image(systemName: e.symbol).help(e.title).tag(e)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Messenger ⌘1 · Network ⌘2 · Insights ⌘3 · Settings ⌘4")
    }
}

extension Notification.Name {
    static let allmanCompose = Notification.Name("sh.allman.mac.compose")
    static let allmanSyncWindow = Notification.Name("sh.allman.mac.syncWindow")
}

/// Grabs the hosting NSWindow so we can tag it and tweak it.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { configure(w) } }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let w = nsView.window { configure(w) } }
    }
}

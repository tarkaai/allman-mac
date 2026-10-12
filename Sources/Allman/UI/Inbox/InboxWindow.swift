import AppKit
import SwiftUI

/// The one window. Every experience has the same shape: the sidebar (switcher
/// on top, the signed-in account at the bottom, the experience's own navigation
/// between) and a detail page whose header sits on the toolbar row, left-aligned,
/// with the page's actions on the right.
struct InboxWindow: View {
    @Environment(AppModel.self) private var model
    @State private var choosingSyncWindow = false
    /// Tracks the sidebar so the experience switcher can move to the detail's leading
    /// slot when the column is collapsed (it lives in the sidebar's toolbar otherwise).
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var inbox = model.inbox
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 440)
        } detail: {
            Group {
                switch model.experience {
                case .messenger: MessengerDetail()
                case .network: NetworkDetail()
                case .insights: InsightsView()
                case .settings: SettingsDetail()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    if columns == .detailOnly { ExperienceSwitcher() }
                }
            }
        }
        .navigationTitle("")
        .onReceive(NotificationCenter.default.publisher(for: .allmanCompose)) { _ in
            model.experience = .messenger
            withAnimation(.easeInOut(duration: 0.2)) { columns = .all }
            model.inbox.composing = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .allmanSyncWindow)) { _ in choosingSyncWindow = true }
        .sheet(isPresented: $choosingSyncWindow) { SyncWindowSheet().environment(model) }
        .frame(minWidth: 900, minHeight: 560)
        .background(WindowAccessor { window in
            window.identifier = NSUserInterfaceItemIdentifier("inbox")
            window.tabbingMode = .disallowed
            window.title = "Allman"
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
}

/// Switcher · the experience's navigation · the signed-in account.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.experience {
                case .messenger: ConversationListView()
                case .network: NetworkSidebar()
                case .insights: InsightsSidebar()
                case .settings: SettingsSidebar()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 4)
            ProfileHeader()
        }
        // On the toolbar row, beside the sidebar toggle.
        .toolbar { ToolbarItem(placement: .automatic) { ExperienceSwitcher() } }
    }
}

/// Messenger · Network · Insights · Settings.
struct ExperienceSwitcher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Experience", selection: Binding(get: { model.experience }, set: { e in withAnimation(.easeInOut(duration: 0.25)) { model.experience = e } })) {
            ForEach(AppModel.Experience.allCases) { e in
                Label(e.title, systemImage: e.symbol).tag(e)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .labelStyle(.iconOnly)
        .controlSize(.regular)
        .fixedSize()
        .help("Messenger ⌘1 · Network ⌘2 · Insights ⌘3 · Settings ⌘4")
    }
}

/// The page title block on the toolbar row: avatar or icon, title, up to two subtitle rows.
struct PageHeader: View {
    var avatarURL: URL? = nil
    var symbol: String? = nil
    let title: String
    var titleAccessory: AnyView? = nil
    var line1: String? = nil
    var line2: String? = nil
    var line2Symbol: String? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if avatarURL != nil || symbol == nil {
                AvatarView(url: avatarURL, name: title, size: 34)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 34, height: 34).background(Color.primary.opacity(0.06), in: Circle())
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(title).font(AFont.title).lineLimit(1)
                    if let titleAccessory { titleAccessory }
                }
                if let line1, !line1.isEmpty { Text(line1).font(AFont.meta).foregroundStyle(.secondary).lineLimit(1) }
                if let line2, !line2.isEmpty {
                    HStack(spacing: 3) {
                        if let line2Symbol { Image(systemName: line2Symbol).font(AFont.smallIcon) }
                        Text(line2).font(AFont.micro).lineLimit(1)
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        }
        // A fixed ideal width: toolbar items are measured at their ideal size, and a
        // long headline would otherwise push the whole row into the » overflow.
        .frame(minWidth: 160, idealWidth: 360, maxWidth: 520, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

/// The messenger's detail: the open thread, a draft, or the empty state. The
/// contact inspector hangs off this container (not the thread) so opening it
/// never rebuilds the split view.
struct MessengerDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let inbox = model.inbox
        content
            .inspector(isPresented: Binding(get: { model.inspectorVisible }, set: { v in withAnimation(.easeInOut(duration: 0.25)) { model.inspectorVisible = v } })) {
                Group {
                    if let snap = inbox.selected {
                        ContactInspector(snapshot: snap).id(snap.record.convId)
                    } else {
                        ContentUnavailableView("No conversation", systemImage: "person.crop.circle", description: Text("Select a conversation to see who you're talking to."))
                    }
                }
                .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
            }
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .navigationTitle("")
            // Declared once here (not per thread) so the items keep their place while
            // arrowing through the list; the header hides while the inspector shows it.
            .toolbar {
                ToolbarItem(placement: .navigation) { detailHeader }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) { detailAction }
            }
    }

    @ViewBuilder
    private var detailHeader: some View {
        let inbox = model.inbox
        if let draft = inbox.draft {
            PageHeader(avatarURL: draft.avatarURL, title: draft.name, titleAccessory: AnyView(MessengerBadge(size: 13)), line1: draft.headline ?? "linkedin.com/in/\(draft.slug)")
        } else if let snap = inbox.selected, !model.inspectorVisible {
            PersonHeader(snapshot: snap)
        }
    }

    @ViewBuilder
    private var detailAction: some View {
        let inbox = model.inbox
        if inbox.draft != nil {
            Button { inbox.draft = nil } label: { Label("Discard draft", systemImage: "xmark") }
                .help("Discard this draft")
        } else if inbox.selected != nil, !model.inspectorVisible {
            Button { model.toggleInspector() } label: { Label("Contact Details", systemImage: "info.circle") }
                .help("Show contact details (⌥⌘I)")
        }
    }

    @ViewBuilder
    private var content: some View {
        let inbox = model.inbox
        if let draft = inbox.draft {
            DraftThreadView(recipient: draft).id(draft.convId)
        } else if let snap = inbox.selected {
            ThreadView(snapshot: snap).id(snap.record.convId)
        } else if inbox.isLoading {
            ProgressView("Loading conversations…")
        } else if inbox.snapshots.isEmpty {
            ContentUnavailableView {
                Label("No conversations yet", systemImage: "tray")
            } description: {
                Text(model.engine.status == .needsLogin ? "Sign in to start syncing." : "The first sync will fill this in.")
            } actions: {
                if model.engine.status == .needsLogin { Button("Sign in to LinkedIn") { model.engine.login() } }
            }
        } else {
            ContentUnavailableView("Select a conversation", systemImage: "bubble.left.and.bubble.right", description: Text("\(inbox.snapshots.count) conversations · \(inbox.unreadCount) unread"))
        }
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

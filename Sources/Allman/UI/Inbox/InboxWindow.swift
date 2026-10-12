import AppKit
import SwiftUI

/// The one window. Every experience has the same shape: the sidebar (the chrome
/// bar — sidebar toggle, then the experience switcher — on its toolbar row, the
/// signed-in account at the bottom, the experience's own navigation between) and
/// a detail page whose header sits on the toolbar row, left-aligned, with the
/// page's actions on the right.
///
/// Toolbar rules (see docs/UI-RULES.md): the toolbar background is the system's
/// (never hidden, never painted) so every column gets the same soft fade as
/// content scrolls under it; items are declared once, in a stable structure, and
/// change *inside* rather than appearing and disappearing, so nothing on the
/// toolbar row ever re-flows while arrowing through the list or toggling panels.
struct InboxWindow: View {
    @Environment(AppModel.self) private var model
    @State private var choosingSyncWindow = false
    /// The sidebar column. The chrome bar lives in the sidebar's toolbar and moves
    /// to the detail's leading slot — same order — while the sidebar is collapsed.
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var inbox = model.inbox
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(columns: $columns)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 440)
                // Our own toggle sits at the far left of the chrome bar instead.
                .toolbar(removing: .sidebarToggle)
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
                    if columns == .detailOnly { ChromeBar(columns: $columns) }
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

/// Chrome bar · the experience's navigation · the signed-in account.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var columns: NavigationSplitViewVisibility

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
        // On the toolbar row, right after the window buttons. (`.automatic` here is the
        // sidebar's own section; `.navigation` would be merged into the detail's leading slot.)
        // Only while the column is shown: a hidden sidebar's items fall into the » overflow.
        .toolbar { if columns != .detailOnly { ToolbarItem(placement: .automatic) { ChromeBar(columns: $columns) } } }
    }
}

/// Sidebar toggle (always far left), then Messenger · Network · Insights · Settings.
/// One view, one order, wherever it is placed.
struct ChromeBar: View {
    @Binding var columns: NavigationSplitViewVisibility

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { columns = columns == .detailOnly ? .all : .detailOnly }
            } label: {
                Label(columns == .detailOnly ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.leading")
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .help("Toggle sidebar (⌃⌘S)")
            .uiProbe("sidebar-toggle")
            ExperienceSwitcher()
        }
        .uiProbe("chrome-bar")
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
        .uiProbe("experience-switcher")
    }
}

/// The page title block on the toolbar row: avatar or icon, title, up to two subtitle rows.
struct PageHeader: View {
    var avatarURL: URL? = nil
    var avatar: AnyView? = nil
    var symbol: String? = nil
    let title: String
    var titleAccessory: AnyView? = nil
    var line1: String? = nil
    var line2: String? = nil
    var line2Symbol: String? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let avatar {
                avatar
            } else if avatarURL != nil || symbol == nil {
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

/// The one control for the contact panel: `i`, far right of the window, same glyph
/// whether the panel is open or closed.
struct InspectorToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.toggleInspector() } label: { Label("Contact Details", systemImage: "info.circle") }
            .help(model.inspectorVisible ? "Hide contact details (⌥⌘I)" : "Show contact details (⌥⌘I)")
            .uiProbe("inspector-toggle")
    }
}

/// The messenger's detail: the open thread, a draft, or the empty state, with the
/// contact panel as a trailing column *inside* this view. (Not `.inspector`: that
/// squeezes the whole split view while it animates, so the sidebar slides away and
/// back — the "jumpy" open/close.) The toolbar items are declared here, once.
struct MessengerDetail: View {
    @Environment(AppModel.self) private var model
    static let panelWidth: CGFloat = 300

    var body: some View {
        let inbox = model.inbox
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.inspectorVisible, inbox.draft == nil, let snap = inbox.selected {
                ContactInspector(snapshot: snap)
                    .id(snap.record.convId)
                    .frame(width: Self.panelWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        // Not `.clipped()`: the panel's header lives in the toolbar band above this view's bounds.
        .animation(.easeInOut(duration: 0.25), value: model.inspectorVisible)
        .navigationTitle("")
        // Declared once here (not per thread) so the items keep their place while
        // arrowing through the list; the header fades out while the panel shows it.
        // The `i` is the one control for the panel and never moves.
        .toolbar {
            ToolbarItem(placement: .navigation) { detailHeader }
                .sharedBackgroundVisibility(.hidden)
            // The panel's header, above the panel (the band's scroll-edge effect would
            // wash out a header drawn as content). Always declared — a toolbar item that
            // comes and goes throws every item into the » overflow on macOS 26 — and
            // collapsed to nothing while the panel is closed.
            ToolbarItem(placement: .primaryAction) { panelHeader }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) { detailAction }
        }
    }

    /// Width the `i` takes at the trailing end of the toolbar (button plus spacing).
    static let toggleSlot: CGFloat = 60

    @ViewBuilder
    private var detailHeader: some View {
        let inbox = model.inbox
        if let draft = inbox.draft {
            PageHeader(avatarURL: draft.avatarURL, title: draft.name, titleAccessory: AnyView(MessengerBadge(size: 13)), line1: draft.headline ?? "linkedin.com/in/\(draft.slug)")
        } else if let snap = inbox.selected {
            // Collapsed (not just faded) while the panel is open: the toolbar measures
            // every item, and a hidden-but-wide header plus the panel header overflows.
            PersonHeader(snapshot: snap)
                .frame(width: model.inspectorVisible ? 0 : nil, alignment: .leading)
                .clipped()
                .opacity(model.inspectorVisible ? 0 : 1)
                .allowsHitTesting(!model.inspectorVisible)
                .accessibilityHidden(model.inspectorVisible)
                .uiProbe("thread-header")
        }
    }

    @ViewBuilder
    private var panelHeader: some View {
        let inbox = model.inbox
        let open = model.inspectorVisible && inbox.draft == nil && inbox.selected != nil
        // Real header content even while collapsed (a bare `Color` makes the toolbar draw a glass capsule).
        Group {
            if let snap = inbox.selected { InspectorHeader(snapshot: snap) } else { Text("") }
        }
        .frame(width: open ? Self.panelWidth - Self.toggleSlot : 1, height: 34, alignment: .leading)
        .clipped()
        .opacity(open ? 1 : 0)
        .accessibilityHidden(!open)
    }

    @ViewBuilder
    private var detailAction: some View {
        let inbox = model.inbox
        if inbox.draft != nil {
            Button { inbox.draft = nil } label: { Label("Discard draft", systemImage: "xmark") }
                .help("Discard this draft")
        } else if inbox.selected != nil {
            InspectorToggle()
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

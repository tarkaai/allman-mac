import AppKit
import SwiftUI

/// Window chrome constants (see docs/UI-RULES.md).
enum Chrome {
    /// The top band: window buttons, chrome bar and page headers live here.
    static let barHeight: CGFloat = 44
    static let sidebarWidth: CGFloat = 340
    /// Where the chrome bar starts (after the window buttons).
    static let chromeLeading: CGFloat = 76
    /// Leading inset for a page header while the sidebar is collapsed (room for the chrome bar).
    static let collapsedLeading: CGFloat = 262
    static let panelWidth: CGFloat = 300
    /// Room kept at the far right of the messenger bars for the `i`.
    static let trailingSlot: CGFloat = 48
}

/// The one window, with chrome the app draws itself (no system title bar or
/// toolbar): a full-height sidebar, the chrome bar fixed at the top-left of the
/// window (sidebar toggle, then the experience switcher — it never moves), and a
/// detail whose header sits on the same top band. Every experience has this shape.
struct InboxWindow: View {
    @Environment(AppModel.self) private var model
    @State private var choosingSyncWindow = false

    var body: some View {
        @Bindable var inbox = model.inbox
        let collapsed = model.isSidebarCollapsed
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: collapsed ? 0 : Chrome.sidebarWidth, alignment: .trailing)
                    .clipped()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ChromeBar()
                .padding(.leading, Chrome.chromeLeading)
                .frame(height: Chrome.barHeight)
            if model.experience == .messenger, inbox.selected != nil || inbox.draft != nil {
                // One `i`, far right, whatever the panel does.
                HStack { Spacer(); InspectorToggle().padding(.trailing, 12) }
                    .frame(height: Chrome.barHeight)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: collapsed)
        .ignoresSafeArea(.container, edges: .top)
        .onReceive(NotificationCenter.default.publisher(for: .allmanCompose)) { _ in
            model.experience = .messenger
            if model.isSidebarCollapsed { model.toggleSidebar() }
            model.inbox.composing = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .allmanSyncWindow)) { _ in choosingSyncWindow = true }
        .sheet(isPresented: $choosingSyncWindow) { SyncWindowSheet().environment(model) }
        .frame(minWidth: 900, minHeight: 560)
        .background(WindowAccessor { window in
            window.identifier = NSUserInterfaceItemIdentifier("inbox")
            window.tabbingMode = .disallowed
            window.title = "Allman"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            WindowAccessor.centerWindowButtons(window)
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

    @ViewBuilder
    private var detail: some View {
        switch model.experience {
        case .messenger: MessengerDetail()
        case .network: NetworkDetail()
        case .insights: InsightsView()
        case .settings: SettingsDetail()
        }
    }
}

/// Full height, over the top band: the experience's navigation under the chrome
/// bar's band, the signed-in account at the bottom.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Chrome.barHeight)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
            Group {
                switch model.experience {
                case .messenger: ConversationListView()
                case .network: NetworkSidebar()
                case .insights: InsightsSidebar()
                case .settings: SettingsSidebar()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // As a bottom inset (not a sibling): the list knows exactly where its viewport ends.
            .safeAreaInset(edge: .bottom, spacing: 0) { ProfileHeader() }
        }
        .frame(width: Chrome.sidebarWidth)
        .background(Color.primary.opacity(0.045))
        .uiProbe("sidebar")
    }
}

/// Sidebar toggle (always far left), then Messenger · Network · Insights · Settings.
/// Fixed at the top-left of the window; collapsing the sidebar only changes the
/// toggle's look, never its place.
struct ChromeBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Button { model.toggleSidebar() } label: {
                Image(systemName: model.isSidebarCollapsed ? "sidebar.leading" : "sidebar.leading")
                    .symbolVariant(model.isSidebarCollapsed ? .none : .fill)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.canCollapseSidebar ? .secondary : .quaternary)
            .disabled(!model.canCollapseSidebar)
            .keyboardShortcut("s", modifiers: [.control, .command])
            .help(model.canCollapseSidebar ? (model.isSidebarCollapsed ? "Show sidebar (⌃⌘S)" : "Hide sidebar (⌃⌘S)") : "Settings keeps its sidebar")
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

/// A page's top band: header on the left (moved right while the sidebar is
/// collapsed, to clear the chrome bar), actions on the right. Content scrolls
/// under it with the soft fade (`safeAreaBar`).
struct PageBar<Leading: View, Trailing: View>: View {
    @Environment(AppModel.self) private var model
    /// Fixed leading inset (the contact panel's bar), else follows the sidebar state.
    var fixedLeading: CGFloat? = nil
    var trailingSlot: CGFloat = 12
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            leading()
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.leading, fixedLeading ?? (model.isSidebarCollapsed ? Chrome.collapsedLeading : 16))
        .padding(.trailing, trailingSlot)
        .frame(maxWidth: .infinity, minHeight: Chrome.barHeight, maxHeight: Chrome.barHeight)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }
}

/// The page title block on the top band: avatar or icon, title, up to two subtitle rows.
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
                AvatarView(url: avatarURL, name: title, size: 32)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 32, height: 32).background(Color.primary.opacity(0.06), in: Circle())
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
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

/// The one control for the contact panel: `i`, far right of the window, same glyph
/// whether the panel is open or closed.
struct InspectorToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.toggleInspector() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.inspectorVisible ? Color.accentColor : .secondary)
        .help(model.inspectorVisible ? "Hide contact details (⌥⌘I)" : "Show contact details (⌥⌘I)")
        .uiProbe("inspector-toggle")
    }
}

/// The messenger's detail: the open thread, a draft, or the empty state, with the
/// contact panel as a trailing column inside this view. Each column carries its own
/// top band; the `i` is the window's (InboxWindow) so it never moves.
struct MessengerDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let inbox = model.inbox
        let panel = model.inspectorVisible && inbox.draft == nil && inbox.selected != nil
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaBar(edge: .top) {
                    PageBar(trailingSlot: Chrome.trailingSlot) {
                        if !panel { detailHeader }
                    } trailing: { EmptyView() }
                }
            if panel, let snap = inbox.selected {
                ContactInspector(snapshot: snap)
                    .id(snap.record.convId)
                    .safeAreaBar(edge: .top) {
                        PageBar(fixedLeading: 16, trailingSlot: Chrome.trailingSlot) {
                            InspectorHeader(snapshot: snap)
                        } trailing: { EmptyView() }
                    }
                    .background(Color.primary.opacity(0.035))
                    .frame(width: Chrome.panelWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.inspectorVisible)
    }

    @ViewBuilder
    private var detailHeader: some View {
        let inbox = model.inbox
        if let draft = inbox.draft {
            let all = inbox.draftRecipients
            PageHeader(
                avatarURL: all.count == 1 ? draft.avatarURL : nil,
                avatar: all.count > 1 ? AnyView(GroupAvatarView(members: all.map(\.asParticipant), size: 32)) : nil,
                title: all.map(\.name).joined(separator: ", "),
                titleAccessory: AnyView(MessengerBadge(size: 13)),
                line1: all.count > 1 ? "New group message · \(all.count) people" : (draft.headline ?? "linkedin.com/in/\(draft.slug)")
            )
            .uiProbe("thread-header")
        } else if let snap = inbox.selected {
            PersonHeader(snapshot: snap).uiProbe("thread-header")
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

    /// The window buttons sit on the chrome bar's band: centered on `Chrome.barHeight`.
    static func centerWindowButtons(_ window: NSWindow) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let b = window.standardWindowButton(kind), let bar = b.superview else { continue }
            let y = bar.bounds.height - (Chrome.barHeight - b.frame.height) / 2 - b.frame.height
            if abs(b.frame.origin.y - y) > 0.5 { b.setFrameOrigin(NSPoint(x: b.frame.origin.x, y: y)) }
        }
    }
}

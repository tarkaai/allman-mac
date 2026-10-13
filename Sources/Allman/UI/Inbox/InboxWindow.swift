import AppKit
import SwiftUI

/// Window chrome constants (see docs/UI-RULES.md).
enum Chrome {
    /// The top band: window buttons, chrome bar and page headers live here.
    static let barHeight: CGFloat = 52
    static let sidebarWidth: CGFloat = 340
    /// Where the chrome bar starts (after the window buttons).
    static let chromeLeading: CGFloat = 76
    /// A page header keeps its place whether the sidebar is open or collapsed.
    static let headerLeading: CGFloat = sidebarWidth + 16
    static let panelWidth: CGFloat = 300
    /// Room kept at the far right of the messenger bars for the thread actions and the `i`.
    static let trailingSlot: CGFloat = 212
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
        GeometryReader { geo in
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: collapsed ? 0 : Chrome.sidebarWidth, alignment: .trailing)
                    .clipped()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Bubbles are sized for the detail with the sidebar open and the panel closed, so
            // collapsing the sidebar or opening the panel only moves whitespace.
            .environment(\.detailFullWidth, max(300, geo.size.width - Chrome.sidebarWidth))
            // Chrome bar at the top-left, the new-message button at the sidebar's top-right
            // (beside the chrome bar once the sidebar is collapsed).
            HStack(spacing: 10) {
                ChromeBar()
                if collapsed { composeButton }
            }
            .padding(.leading, Chrome.chromeLeading)
            .frame(height: Chrome.barHeight)
            if !collapsed {
                composeButton
                    .padding(.leading, Chrome.sidebarWidth - 12 - 28)
                    .frame(height: Chrome.barHeight)
            }
            // The thread's actions and the one `i` — far right, whatever the panel or sidebar do.
            if model.experience == .messenger, inbox.selected != nil || inbox.draft != nil {
                HStack(spacing: 2) {
                    Spacer()
                    if let id = inbox.selectedConvId, inbox.draft == nil { ThreadActions(convId: id) }
                    InspectorToggle()
                }
                .padding(.trailing, 12)
                .frame(height: Chrome.barHeight)
                .uiProbe("top-actions")
            }
        }
        }
        .animation(.easeInOut(duration: 0.25), value: collapsed)
        .ignoresSafeArea(.container, edges: .top)
        .onReceive(NotificationCenter.default.publisher(for: .allmanCompose)) { _ in model.startNewMessage() }
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

    private var composeButton: some View {
        IconButton(symbol: "square.and.pencil", help: "New message (⌘N) — pick several people for a group", size: .band) { model.startNewMessage() }
            .uiProbe("compose-button")
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
            // One real symbol (`sidebar.leading`); "on" tint while the sidebar is open. Never disabled —
            // on Settings it is simply a no-op with a tooltip saying so.
            IconButton(symbol: "sidebar.leading",
                       help: model.canCollapseSidebar ? (model.isSidebarCollapsed ? "Show sidebar (⌃⌘S)" : "Hide sidebar (⌃⌘S)") : "Settings keeps its sidebar",
                       size: .band, on: !model.isSidebarCollapsed, shortcut: "s", modifiers: [.control, .command]) { model.toggleSidebar() }
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
        // Our own segmented control: one tooltip and one hover state per page.
        HStack(spacing: 2) {
            ForEach(Array(AppModel.Experience.allCases.enumerated()), id: \.element) { i, e in
                let on = model.experience == e
                IconButton(symbol: e.symbol, help: "\(e.title) (⌘\(i + 1))", size: .band, on: on) {
                    withAnimation(.easeInOut(duration: 0.25)) { model.experience = e }
                }
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Color.accentColor.opacity(0.18) : .clear))
                .uiProbe("experience-\(e.rawValue)")
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .padding(.leading, fixedLeading ?? (model.isSidebarCollapsed ? Chrome.headerLeading : 16))
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
        IconButton(symbol: "info.circle", help: model.inspectorVisible ? "Hide contact details (⌥⌘I)" : "Show contact details (⌥⌘I)", size: .band, on: model.inspectorVisible) { model.toggleInspector() }
            .uiProbe("inspector-toggle")
    }
}

/// Pin · labels · snooze/remind · note · archive for the open thread, on the top band
/// beside the `i` — same size, same place, panel open or closed. The label, snooze
/// and note popovers hang off their buttons.
struct ThreadActions: View {
    @Environment(AppModel.self) private var model
    let convId: String

    var body: some View {
        @Bindable var inbox = model.inbox
        let id = convId
        HStack(spacing: 2) {
            IconButton(symbol: inbox.isPinned(id) ? "pin.fill" : "pin", help: inbox.isPinned(id) ? "Unpin (⇧⌘P)" : "Pin (⇧⌘P)", size: .band, on: inbox.isPinned(id)) { inbox.togglePin(id) }
                .disabled(!inbox.isPinned(id) && !inbox.canPinMore)
                .uiProbe("action-pin")
            IconButton(symbol: inbox.organizer.labels(for: id).isEmpty ? "tag" : "tag.fill", help: "Labels (L)", size: .band) { inbox.showLabelPicker = true }
                .popover(isPresented: $inbox.showLabelPicker, arrowEdge: .bottom) { LabelPicker(convId: id).environment(model) }
                .uiProbe("action-label")
            IconButton(symbol: inbox.organizer.snooze(id) == nil ? "clock" : "clock.fill", help: "Snooze or remind (H)", size: .band) { inbox.showSnoozePicker = true }
                .popover(isPresented: $inbox.showSnoozePicker, arrowEdge: .bottom) { SnoozePicker(convId: id) { inbox.showSnoozePicker = false }.environment(model) }
                .uiProbe("action-snooze")
            IconButton(symbol: inbox.organizer.note(id).isEmpty ? "note.text" : "note.text.badge.plus", help: "Note (N)", size: .band) { inbox.showNoteEditor = true }
                .popover(isPresented: $inbox.showNoteEditor, arrowEdge: .bottom) { NoteEditor(convId: id, compact: true).environment(model) }
                .uiProbe("action-note")
            IconButton(symbol: inbox.isArchived(id) ? "tray.and.arrow.up" : "archivebox", help: inbox.isArchived(id) ? "Unarchive (E)" : "Archive (E)", size: .band) { inbox.toggleArchive(id) }
                .uiProbe("action-archive")
        }
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
                    // With the panel open the actions sit above the panel, so the header may use the whole column.
                    PageBar(trailingSlot: panel ? 12 : Chrome.trailingSlot) {
                        detailHeader // stays, panel or no panel
                    } trailing: { EmptyView() }
                }
            if inbox.draft == nil, let snap = inbox.selected {
                // The column's width animates (not a slide-in over a jump): the thread narrows
                // at the same pace the panel appears.
                ContactInspector(snapshot: snap)
                    .id(snap.record.convId)
                    .safeAreaBar(edge: .top) { Color.clear.frame(height: Chrome.barHeight).uiProbe("panel-band") }
                    .background(Color.primary.opacity(0.035))
                    .frame(width: Chrome.panelWidth)
                    .frame(width: panel ? Chrome.panelWidth : 0, alignment: .leading)
                    .clipped()
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

/// The detail's full width (panel or not), so bubbles are sized for the room the
/// thread has when the panel is closed and only whitespace collapses when it opens.
private struct DetailFullWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var detailFullWidth: CGFloat {
        get { self[DetailFullWidthKey.self] }
        set { self[DetailFullWidthKey.self] = newValue }
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

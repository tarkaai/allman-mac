import SwiftUI

/// The sidebar, top to bottom: who's signed in, the inbox bar (labels as
/// inboxes, filters, new message), search, pins for the current inbox, then
/// the conversation list. Per-thread actions live on the rows.
struct ConversationListView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool
    /// Return in the compose search picks the best match.
    @State private var composeSubmit = 0
    /// How far past the visible edge an edge-anchored scroll lands (learned per edge), and the last such scroll.
    @State private var topBias: CGFloat = 0
    @State private var bottomBias: CGFloat = 0
    @State private var lastEdgeScroll: (id: String, top: Bool, bias: CGFloat)?

    var body: some View {
        @Bindable var inbox = model.inbox
        let rows = inbox.filtered
        let hits = inbox.isSearching ? inbox.messageHits : []
        let pins = inbox.pinnedInView
        let showPins = !pins.isEmpty && !inbox.isSearching
        VStack(spacing: 0) {
            InboxBar().accessibilityElement(children: .contain).uiProbe("inbox-bar").padding(.top, 4)
            if inbox.composing {
                SearchField(text: $inbox.composeQuery, focused: $searchFocused, prompt: "To: a name, or linkedin.com/in/…", onSubmit: { composeSubmit += 1 }, onCancel: { inbox.composing = false })
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
                    .onAppear { searchFocused = true }
            } else {
                SearchField(text: $inbox.searchText, focused: $searchFocused)
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
                    .uiProbe("search-field")
            }
            Group {
                if inbox.composing {
                    PeopleSearchPane(query: inbox.composeQuery, submitToken: composeSubmit)
                } else if rows.isEmpty && hits.isEmpty && !inbox.isLoading && !showPins && !inbox.searchingMessages {
                    ContentUnavailableView {
                        Label(emptyTitle(inbox), systemImage: inbox.filter == .unread ? "checkmark.circle" : "magnifyingglass")
                    } description: {
                        Text(inbox.searchText.isEmpty ? "Nothing matches this inbox." : (inbox.searchText.trimmingCharacters(in: .whitespaces).count < 3 ? "Type at least three characters to search inside messages." : "No conversation or message contains this."))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                    List(selection: $inbox.sidebarSelection) {
                        if showPins {
                            PinnedGrid(pins: pins)
                                .accessibilityElement(children: .contain).uiProbe("pinned-grid")
                                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 6, trailing: 8))
                                .listRowSeparator(.hidden)
                                .selectionDisabled()
                        }
                        if inbox.isSearching {
                            if !rows.isEmpty {
                                Section("Conversations") {
                                    ForEach(rows) { snap in row(snap) }
                                }
                            }
                            if !hits.isEmpty || inbox.searchingMessages {
                                Section {
                                    ForEach(hits) { hit in
                                        if let snap = inbox.byId[hit.convId] {
                                            MessageHitRow(hit: hit, snapshot: snap, query: inbox.searchText).tag(hit.id)
                                        }
                                    }
                                } header: {
                                    HStack {
                                        Text(hits.isEmpty ? "Messages" : "Messages (\(hits.count)\(hits.count >= 200 ? "+" : ""))")
                                        if inbox.searchingMessages { ProgressView().controlSize(.mini) }
                                    }
                                }
                            }
                        } else {
                            ForEach(rows) { snap in row(snap) }
                        }
                    }
                    // Plain, not sidebar: the selection highlight runs edge to edge (no inset, no rounding).
                    .listStyle(.plain)
                    // A thread moving (a send, a new message) slides to its place; scoped to the
                    // list so the thread's own layout never animates with it.
                    .animation(.easeInOut(duration: 0.25), value: rows.map(\.record.convId))
                    .scrollContentBackground(.hidden)
                    .contentMargins(.vertical, 0, for: .scrollContent)
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .uiProbe("conversation-list", always: true)
                    .focused($listFocused)
                    .onKeyPress(.return) { inbox.requestFocus(.composer); return .handled }
                    .onKeyPress(.space) { inbox.requestFocus(.composer); return .handled }
                    .onKeyPress(characters: .letters, phases: .down) { press in
                        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
                        return handleKey(press.characters) ? .handled : .ignored
                    }
                    // Keyboard moves (⌘↑/↓, j/k, next unread) keep the selected row on screen.
                    // Only selections that didn't come from a click on a visible row scroll the
                    // list (keyboard, menus, notifications, drafts). A click never moves it.
                    .onChange(of: inbox.revealToken) { _, _ in
                        guard let id = inbox.revealId, inbox.selectedConvId == id, inbox.filtered.contains(where: { $0.record.convId == id }) else { return }
                        reveal(id, proxy)
                        Task { @MainActor in
                            // Rows re-populate after an inbox switch (and the list may restore an old
                            // offset afterwards); a later pass lands once that has settled.
                            for ms in [220, 400] {
                                try? await Task.sleep(for: .milliseconds(ms))
                                guard inbox.selectedConvId == id else { return }
                                reveal(id, proxy)
                            }
                        }
                    }
                    // The list is rebuilt when an inbox goes from empty to populated; a selection made
                    // in the same beat is no "change" to observe, so land on it here too.
                    .onAppear {
                        guard let id = inbox.selectedConvId, inbox.revealId == id, Date().timeIntervalSince(inbox.revealAt) < 2,
                              inbox.filtered.contains(where: { $0.record.convId == id }) else { return }
                        Task { @MainActor in
                            for ms in [50, 250, 450] {
                                try? await Task.sleep(for: .milliseconds(ms))
                                guard inbox.selectedConvId == id else { return }
                                reveal(id, proxy)
                            }
                        }
                    }
                    // A different inbox starts at its top.
                    .onChange(of: inbox.filter) { _, _ in
                        guard let first = inbox.filtered.first?.record.convId, inbox.selectedConvId == nil else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            proxy.scrollTo(first, anchor: .top)
                        }
                    }
                    }
                }
            }
        }
        .onChange(of: inbox.focusToken) { _, _ in
            switch inbox.focusTarget {
            case .list: listFocused = true
            case .search: searchFocused = true
            case .composer: break // the composer observes this itself
            }
        }
        .onChange(of: inbox.composing) { _, on in if on { searchFocused = true } else { listFocused = true } }
        .onAppear { listFocused = true }
        .sheet(item: Binding(get: { inbox.renamingLabel }, set: { inbox.renamingLabel = $0 })) { RenameLabelSheet(label: $0).environment(model) }
    }

    /// Scroll only when the row is not fully on screen, and then only to the nearer edge —
    /// the least movement, and none at all when it is already visible. Visibility comes
    /// from the rows' live AppKit frames (a List recycles cells without `onDisappear`,
    /// so SwiftUI-side bookkeeping goes stale). A `.top`-anchored scroll lands a fixed
    /// distance above the visible edge on macOS 26 (the column's safe-area inset leaks
    /// into the arithmetic); the error is measured once and compensated from then on.
    private func reveal(_ id: String, _ proxy: ScrollViewProxy) {
        let inbox = model.inbox
        guard let list = UIProbeRegistry.first("conversation-list") else { return }
        let row = UIProbeRegistry.first("row-\(id)")
        if let r = row, r.minY >= list.minY - 0.5, r.maxY <= list.maxY + 0.5 { lastEdgeScroll = nil; return }
        let above: Bool
        if let r = row {
            above = r.minY < list.minY
            // The previous edge-anchored scroll for this row landed off by this much: learn the bias.
            if let used = lastEdgeScroll, used.id == id {
                if used.top, above { topBias = used.bias + (list.minY - r.minY) }
                if !used.top, !above { bottomBias = used.bias + (r.maxY - list.maxY) }
            }
        } else {
            // Not materialized: above or below everything that is.
            let idx = inbox.filtered.firstIndex { $0.record.convId == id } ?? 0
            let shown = UIProbeRegistry.liveIds(prefix: "row-").compactMap { k in inbox.filtered.firstIndex { "row-\($0.record.convId)" == k } }
            above = idx < (shown.min() ?? Int.max)
        }
        let rowH = row?.height ?? 48
        let span = max(1, list.height - rowH)
        let anchor: UnitPoint = above
            ? UnitPoint(x: 0, y: min(0.9, max(0, topBias / span)))
            : UnitPoint(x: 0, y: max(0.1, min(1, 1 - bottomBias / span)))
        lastEdgeScroll = (id, above, above ? topBias : bottomBias)
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: anchor) }
    }

    private func row(_ snap: ConversationSnapshot) -> some View {
        let inbox = model.inbox
        let id = snap.record.convId
        return ConversationRow(snapshot: snap, unreadCount: inbox.unreadCount(snap))
            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
            .listRowSeparator(.hidden)
            .tag(id)
            .id(id)

            .contextMenu { ConversationActions(convId: id, asMenu: true) }
            // Trackpad gestures, Mail-style: swipe right to read/pin, left to archive/snooze/label.
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if inbox.isUnread(snap) {
                    Button { inbox.markSeen(id) } label: { Label("Read", systemImage: "envelope.open") }.tint(.blue)
                }
                Button { inbox.togglePin(id) } label: { Label(inbox.isPinned(id) ? "Unpin" : "Pin", systemImage: inbox.isPinned(id) ? "pin.slash" : "pin") }.tint(.orange)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button { inbox.toggleArchive(id) } label: { Label(inbox.isArchived(id) ? "Unarchive" : "Archive", systemImage: inbox.isArchived(id) ? "tray.and.arrow.up" : "archivebox") }.tint(.gray)
                Button { inbox.select(id); inbox.showSnoozePicker = true } label: { Label("Snooze", systemImage: "clock") }.tint(.purple)
                Button { inbox.select(id); inbox.showLabelPicker = true } label: { Label("Label", systemImage: "tag") }.tint(.indigo)
            }
    }

    /// j/k move, e archive, h snooze, l label, n note, u unread view, i details.
    private func handleKey(_ chars: String) -> Bool {
        let inbox = model.inbox
        switch chars {
        case "j": inbox.selectNext(); return true
        case "k": inbox.selectPrevious(); return true
        case "e": if let id = inbox.selectedConvId { inbox.toggleArchive(id) }; return true
        case "h": if inbox.selectedConvId != nil { inbox.showSnoozePicker = true }; return true
        case "l": if inbox.selectedConvId != nil { inbox.showLabelPicker = true }; return true
        case "n": if inbox.selectedConvId != nil { inbox.showNoteEditor = true }; return true
        case "u": inbox.filter = inbox.filter == .unread ? .all : .unread; return true
        case "i": model.toggleInspector(); return true
        default: return false
        }
    }

    private func emptyTitle(_ inbox: InboxModel) -> String {
        if !inbox.searchText.isEmpty { return "No matches" }
        switch inbox.filter {
        case .unread: return "All caught up"
        case .needsReply: return "Nothing waiting on you"
        case .awaitingReply: return "No open threads"
        case .reminders: return "No snoozes or reminders"
        case .archived: return "Nothing archived"
        case .label(let id): return "Nothing in \(inbox.organizer.label(id)?.name ?? "this inbox")"
        default: return "No conversations"
        }
    }
}

// MARK: - Profile header

/// Who is signed in, with the account actions collapsed behind a chevron.
struct ProfileHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if let session = model.current {
                AvatarView(url: session.avatarURL, name: session.displayName, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName).font(AFont.title).lineLimit(1)
                    HStack(spacing: 5) {
                        MessengerBadge(size: 11)
                        Text("@\(session.slug)").font(AFont.meta).foregroundStyle(.secondary).lineLimit(1)
                        Circle().fill(statusColor(model.engine.status)).frame(width: 6, height: 6)
                        Text(model.engine.isSyncing ? "Syncing" : model.engine.status.shortLabel).font(AFont.meta).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            } else {
                Image(systemName: "person.crop.circle").font(.system(size: 28)).foregroundStyle(.secondary).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not signed in").font(AFont.title).foregroundStyle(.secondary)
                    Text(StorePaths.overrideIsInvalid ? "Store override is not a directory" : "Add an account to start").font(AFont.meta).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            Menu {
                if model.sessions.count > 1 {
                    Picker("Account", selection: Binding(get: { model.currentId ?? "" }, set: { model.select(accountId: $0) })) {
                        ForEach(model.sessions) { s in Text("\(s.displayName) (@\(s.slug))").tag(s.id) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                }
                Button("Sync Now") { model.engine.syncNow(from: "1d") }.disabled(model.engine.isSyncing)
                Button("Sync Older History…") { NotificationCenter.default.post(name: .allmanSyncWindow, object: nil) }
                if let url = model.current.map({ URL(string: "https://www.linkedin.com/in/\($0.slug)/")! }) {
                    Button("Open My LinkedIn Profile") { NSWorkspace.shared.open(url) }
                }
                Divider()
                Button(model.isAddingAccount ? "Waiting for browser sign-in…" : "Add Account…") { model.addAccount() }.disabled(model.isAddingAccount)
                if let session = model.current {
                    if session.isAuthenticated {
                        Button("Sign Out @\(session.slug)") { model.signOut(session) }
                    } else {
                        Button("Sign In…") { session.engine.login() }.disabled(session.engine.status == .loggingIn)
                    }
                }
                Divider()
                Button("Settings…") { model.show(.settings) }
            } label: {
                BarIcon("chevron.down.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Account")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
        .uiProbe("profile-header")
    }

    private func statusColor(_ status: SyncEngine.Status) -> Color {
        switch status {
        case .live: return .green
        case .connecting, .reconnecting, .idle, .loggingIn: return .yellow
        case .offline: return .gray
        case .needsLogin, .noBinary, .error: return .orange
        }
    }
}

// MARK: - Inbox bar

/// Inboxes (All, Unread, every label), the filter menu, new message, and the
/// actions for the selected thread (also the anchor for their popovers).
struct InboxBar: View {
    @Environment(AppModel.self) private var model
    @State private var creatingLabel = false
    @State private var newName = ""
    @State private var newIcon = InboxLabel.icons[0]

    var body: some View {
        @Bindable var inbox = model.inbox
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Menu {
                    Picker("Filter", selection: $inbox.filter) {
                        ForEach(InboxModel.Filter.builtIn) { f in Label(f.title, systemImage: f.symbol).tag(f) }
                        Divider()
                        Label("Snoozed & reminders", systemImage: InboxModel.Filter.reminders.symbol).tag(InboxModel.Filter.reminders)
                        Label("Archived", systemImage: InboxModel.Filter.archived.symbol).tag(InboxModel.Filter.archived)
                    }
                    .pickerStyle(.inline).labelsHidden()
                    Divider()
                    Button("Mark All as Read") { inbox.markAllSeen() }.disabled(inbox.unreadCount == 0)
                } label: {
                    BarIcon(inbox.filter == .all || inbox.filter.isLabel ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .frame(width: 24, height: 22)
                .help("Filter: \(inbox.filter.title)")
                .uiProbe("filter-menu")
                Text(title(inbox.filter)).font(AFont.title).lineLimit(1).frame(height: 22).uiProbe("inbox-title")
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                Button { creatingLabel = true } label: { BarIcon("tag.badge.plus") }
                    .buttonStyle(.plain)
                    .help("New label (an inbox of its own)")
                    .popover(isPresented: $creatingLabel, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("New label").font(.headline)
                            TextField("Name", text: $newName).textFieldStyle(.roundedBorder).onSubmit(createLabel)
                            IconGrid(selected: $newIcon)
                            HStack { Spacer(); Button("Create", action: createLabel).keyboardShortcut(.defaultAction).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty) }
                        }
                        .padding(12).frame(width: 300)
                        .onAppear { let used = Set(inbox.organizer.labels.map(\.icon)); newIcon = InboxLabel.icons.first { !used.contains($0) } ?? "tag" }
                    }
                Button { inbox.composing.toggle() } label: { BarIcon(inbox.composing ? "xmark.circle" : "square.and.pencil", large: true) }
                    .buttonStyle(.plain)
                    .help(inbox.composing ? "Cancel new message (Esc)" : "New message (⌘N) — pick several people for a group")
                    .uiProbe("compose-button")
                }
            }
            FlowLayout(spacing: 4) {
                chip("All", symbol: "tray.full", filter: .all, count: 0)
                chip("Unread", symbol: "envelope.badge", filter: .unread, count: inbox.unreadCount)
                ForEach(inbox.organizer.labels) { l in
                    Button { inbox.filter = inbox.filter == .label(l.id) ? .all : .label(l.id) } label: {
                        LabelChip(label: l, selected: inbox.filter == .label(l.id), count: inbox.unreadCount(label: l.id))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { LabelMenu(label: l) }
                }
                if !inbox.organizer.snoozes.isEmpty {
                    chip("Snoozed", symbol: "clock", filter: .reminders, count: inbox.dueCount)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func chip(_ name: String, symbol: String, filter: InboxModel.Filter, count: Int) -> some View {
        let inbox = model.inbox
        let on = inbox.filter == filter
        return Button { inbox.filter = on && filter != .all ? .all : filter } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(AFont.chipIcon)
                Text(name)
                if count > 0 { Text("\(count)").foregroundStyle(on ? .primary : .secondary).monospacedDigit() }
            }
            .font(on ? AFont.chipStrong : AFont.chip)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(on ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
            .foregroundStyle(on ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    private func title(_ f: InboxModel.Filter) -> String {
        let inbox = model.inbox
        let total = inbox.snapshots.count
        switch f {
        case .all: return inbox.unreadCount > 0 ? "Inbox · \(inbox.unreadCount) unread" : "Inbox · \(total)"
        case .label(let id): return inbox.organizer.label(id)?.name ?? "Label"
        default: return f.title
        }
    }

    private func createLabel() {
        guard model.inbox.addLabel(newName, icon: newIcon) != nil else { return }
        newName = ""
        creatingLabel = false
    }
}

/// Pin, labels, snooze, note, archive for one thread — as inline icon buttons
/// (the inbox bar, rows on hover) or as menu items (context menus).
struct ConversationActions: View {
    @Environment(AppModel.self) private var model
    let convId: String?
    let asMenu: Bool

    var body: some View {
        @Bindable var inbox = model.inbox
        if let id = convId, let snap = inbox.byId[id] {
            if asMenu {
                Button(inbox.isPinned(id) ? "Unpin" : "Pin") { inbox.togglePin(id) }.disabled(!inbox.isPinned(id) && !inbox.canPinMore)
                if inbox.isUnread(snap) { Button("Mark as Read") { inbox.markSeen(id) } }
                Divider()
                Menu("Labels") {
                    ForEach(inbox.organizer.labels) { l in
                        Button { inbox.toggle(label: l.id, id) } label: { Label(l.name, systemImage: inbox.organizer.has(label: l.id, id) ? "checkmark.circle.fill" : l.icon) }
                    }
                    if !inbox.organizer.labels.isEmpty { Divider() }
                    Button("New Label…") { inbox.select(id); inbox.showLabelPicker = true }
                }
                Menu("Snooze") {
                    ForEach(Array(Snooze.presets().enumerated()), id: \.offset) { _, p in
                        Button("\(p.title) · \(Fmt.reminderTime(p.date))") { inbox.snooze(id, until: p.date, hidden: true) }
                    }
                    Divider()
                    Button("Remind me…") { inbox.select(id); inbox.showSnoozePicker = true }
                    if inbox.organizer.snooze(id) != nil { Button("Clear Snooze / Reminder") { inbox.clearSnooze(id) } }
                }
                Button(inbox.organizer.note(id).isEmpty ? "Add Note…" : "Edit Note…") { inbox.select(id); inbox.showNoteEditor = true }
                Button(inbox.isArchived(id) ? "Unarchive" : "Archive") { inbox.toggleArchive(id) }
                Divider()
                if let url = snap.record.linkedInProfileURL { Button("Open LinkedIn Profile") { NSWorkspace.shared.open(url) } }
                if let url = snap.record.linkedInThreadURL { Button("Open Thread on LinkedIn") { NSWorkspace.shared.open(url) } }
            } else {
                HStack(spacing: 0) {
                    icon(inbox.isPinned(id) ? "pin.fill" : "pin", help: inbox.isPinned(id) ? "Unpin (⇧⌘P)" : "Pin (⇧⌘P)") { inbox.togglePin(id) }
                        .disabled(!inbox.isPinned(id) && !inbox.canPinMore)
                    icon(inbox.organizer.labels(for: id).isEmpty ? "tag" : "tag.fill", help: "Labels (L)") { inbox.showLabelPicker = true }
                        .popover(isPresented: $inbox.showLabelPicker, arrowEdge: .bottom) { LabelPicker(convId: id).environment(model) }
                    icon(inbox.organizer.snooze(id) == nil ? "clock" : "clock.fill", help: "Snooze or remind (H)") { inbox.showSnoozePicker = true }
                        .popover(isPresented: $inbox.showSnoozePicker, arrowEdge: .bottom) { SnoozePicker(convId: id) { inbox.showSnoozePicker = false }.environment(model) }
                    icon(inbox.organizer.note(id).isEmpty ? "note.text" : "note.text.badge.plus", help: "Note (N)") { inbox.showNoteEditor = true }
                        .popover(isPresented: $inbox.showNoteEditor, arrowEdge: .bottom) { NoteEditor(convId: id, compact: true).environment(model) }
                    icon(inbox.isArchived(id) ? "tray.and.arrow.up" : "archivebox", help: inbox.isArchived(id) ? "Unarchive (E)" : "Archive (E)") { inbox.toggleArchive(id) }
                }
            }
        } else if !asMenu {
            HStack(spacing: 0) {
                ForEach(["pin", "tag", "clock", "note.text", "archivebox"], id: \.self) { icon($0, help: "Select a conversation") {}.disabled(true) }
            }
        }
    }

    private func icon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { BarIcon(name) }
            .buttonStyle(.plain)
            .help(help)
    }
}

/// One size and weight for every icon in the inbox bar, so they line up.
struct BarIcon: View {
    let name: String
    var prominent = false
    /// The new-message button: a step up from the rest of the bar.
    var large = false

    init(_ name: String, prominent: Bool = false, large: Bool = false) { self.name = name; self.prominent = prominent; self.large = large }

    var body: some View {
        Image(systemName: name)
            .font(large ? .system(size: 17, weight: .medium) : AFont.icon)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(prominent ? Color.accentColor : Color.secondary)
            .frame(width: large ? 30 : 24, height: large ? 28 : 22)
            .contentShape(Rectangle())
    }
}

// MARK: - Search

struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var prompt = "Search people and messages"
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(AFont.icon).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(AFont.body)
                .focused(focused)
                .onSubmit(onSubmit)
                .onKeyPress(.escape) { onCancel(); return .handled }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(AFont.icon).foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Rows

struct ConversationRow: View {
    @Environment(AppModel.self) private var model
    let snapshot: ConversationSnapshot
    let unreadCount: Int
    @State private var hovering = false

    var body: some View {
        let r = snapshot.record
        let unread = unreadCount > 0
        let org = model.inbox.organizer
        let labels = org.labels(for: r.convId)
        let snooze = org.snooze(r.convId)
        let hasNote = !org.note(r.convId).isEmpty
        HStack(alignment: .center, spacing: 10) {
            ConversationAvatar(record: r, size: 40).uiProbe("row-avatar")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(r.displayName)
                        .font(unread ? AFont.bodyStrong : AFont.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let snooze {
                        Image(systemName: snooze.until <= Date() ? "bell.badge.fill" : (snooze.hidden ? "moon.zzz.fill" : "bell.fill"))
                            .font(AFont.smallIcon).foregroundStyle(.orange)
                            .help((snooze.hidden ? "Snoozed until " : "Reminder ") + Fmt.reminderTime(snooze.until))
                    }
                    if hasNote { Image(systemName: "note.text").font(AFont.smallIcon).foregroundStyle(.secondary).help(org.note(r.convId)) }
                    Text(Fmt.listTime(snapshot.activityDate))
                        .font(AFont.meta)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(alignment: .top, spacing: 6) {
                    // Two preview lines are always reserved, so every row is the same height.
                    if let m = snapshot.lastMessage {
                        Text((m.isFromMe ? "You: " : "") + m.previewText.replacingOccurrences(of: "\n", with: " "))
                            .font(AFont.secondary)
                            .foregroundStyle(unread ? .primary : .secondary)
                            .lineLimit(2, reservesSpace: true)
                    } else {
                        Text(r.headline ?? " ").font(AFont.secondary).foregroundStyle(.tertiary).lineLimit(2, reservesSpace: true)
                    }
                    Spacer(minLength: 0)
                    if unread {
                        Text("\(unreadCount)")
                            .font(AFont.microStrong).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, unreadCount > 9 ? 6 : 0)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Color(nsColor: .systemBlue), in: Capsule())
                            .padding(.top, 1)
                    }
                }
                if !labels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(labels.prefix(4)) { LabelChip(label: $0) }
                        if labels.count > 4 { Text("+\(labels.count - 4)").font(AFont.micro).foregroundStyle(.secondary) }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // Actions ride over the time stamp on hover: no layout shift. The hover
        // region is the composed row *including* the overlay, so moving onto a
        // button doesn't count as leaving the row.
        .overlay(alignment: .trailing) {
            // Centered on the row; the capsule hugs the icons so they sit centered in it.
            if hovering || model.inbox.rowPopover?.convId == r.convId {
                RowActions(convId: r.convId)
                    .background(.regularMaterial, in: Capsule())
                    .uiProbe("row-actions")
                    .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .uiProbe("row-\(r.convId)", always: true)
    }
}

/// Immediate actions on a hovered row; label/snooze/note open the popovers anchored in the inbox bar.
private struct RowActions: View {
    @Environment(AppModel.self) private var model
    let convId: String

    var body: some View {
        let inbox = model.inbox
        HStack(spacing: 0) {
            btn("tag", "Labels") { open(.label) }
                .popover(isPresented: shown(.label), arrowEdge: .bottom) { LabelPicker(convId: convId).environment(model) }
            btn("clock", "Snooze") { open(.snooze) }
                .popover(isPresented: shown(.snooze), arrowEdge: .bottom) { SnoozePicker(convId: convId) { inbox.rowPopover = nil }.environment(model) }
            btn(inbox.isArchived(convId) ? "tray.and.arrow.up" : "archivebox", "Archive") { inbox.toggleArchive(convId) }
        }
        .padding(.horizontal, 4).padding(.vertical, 3)
    }

    /// The popover opens on this row's button; the thread is selected too so the keys agree.
    private func open(_ kind: InboxModel.RowAction) {
        model.inbox.select(convId)
        model.inbox.rowPopover = .init(convId: convId, kind: kind)
    }

    private func shown(_ kind: InboxModel.RowAction) -> Binding<Bool> {
        Binding(
            get: { model.inbox.rowPopover == .init(convId: convId, kind: kind) },
            set: { if !$0, model.inbox.rowPopover?.convId == convId { model.inbox.rowPopover = nil } }
        )
    }

    private func btn(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(AFont.icon)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
        .uiProbe("row-action-icon")
    }
}

/// The people search that replaces the list while composing; Return picks the best match.
struct PeopleSearchPane: View {
    let query: String
    let submitToken: Int
    @State private var pick = 0

    var body: some View {
        PeopleSearchResults(query: query, submitToken: submitToken)
    }
}

/// A full-text search result: who, when, and the matching passage with the
/// query emphasized. Selecting it opens the thread at that message.
struct MessageHitRow: View {
    let hit: MessageHit
    let snapshot: ConversationSnapshot
    let query: String

    var body: some View {
        let r = snapshot.record
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: r.avatarURL, name: r.displayName, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(r.displayName).font(AFont.bodyMedium).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Fmt.relative(hit.message.date)).font(AFont.meta).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(emphasized(hit.snippet(for: query)))
                    .font(AFont.secondary).foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 3)
    }

    private func emphasized(_ snippet: String) -> AttributedString {
        var out = AttributedString((hit.message.isFromMe ? "You: " : "") + snippet)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return out }
        var search = out.startIndex
        while search < out.endIndex, let r = out[search...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            out[r].font = AFont.secondaryStrong
            out[r].foregroundColor = .primary
            search = r.upperBound
        }
        return out
    }
}

/// Messages-style favorites: big avatars at the top of the sidebar, for the current inbox.
struct PinnedGrid: View {
    @Environment(AppModel.self) private var model
    let pins: [ConversationSnapshot]

    var body: some View {
        let inbox = model.inbox
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 10) {
            ForEach(pins) { snap in
                let id = snap.record.convId
                let unread = inbox.unreadCount(snap)
                let selected = inbox.selectedConvId == id
                Button { inbox.select(id) } label: {
                    VStack(spacing: 4) {
                        ConversationAvatar(record: snap.record, size: 56)
                            .overlay(Circle().stroke(selected ? Color.accentColor : .clear, lineWidth: 2.5).padding(-3))
                            .overlay(alignment: .topTrailing) {
                                if unread > 0 {
                                    Text("\(unread)")
                                        .font(AFont.microStrong).monospacedDigit()
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, unread > 9 ? 5 : 0)
                                        .frame(minWidth: 18, minHeight: 18)
                                        .background(Color(nsColor: .systemBlue), in: Capsule())
                                        .overlay(Capsule().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                                        .offset(x: 4, y: -2)
                                }
                            }
                        Text(snap.record.shortName)
                            .font(unread > 0 ? AFont.metaStrong : AFont.meta)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(snap.record.displayName)
                .uiProbe("pin-\(id)")
                // Not `.contextMenu`: inside a List row it applies to the whole row (every pin).
                .overlay(RightClickMenu {
                    var items = [RightClickMenu.Item("Unpin \(snap.record.displayName)") { inbox.togglePin(id) }]
                    if inbox.isUnread(snap) { items.append(.init("Mark as Read") { inbox.markSeen(id) }) }
                    items.append(.init(inbox.isArchived(id) ? "Unarchive" : "Archive") { inbox.toggleArchive(id) })
                    if let url = snap.record.linkedInProfileURL { items.append(.init("Open LinkedIn Profile") { NSWorkspace.shared.open(url) }) }
                    return items
                })
                .draggable(id)
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.first, dragged != id, let to = inbox.pinnedSnapshots.firstIndex(where: { $0.record.convId == id }) else { return false }
                    inbox.movePin(dragged, to: to)
                    return true
                }
            }
        }
    }
}

import SwiftUI

/// The sidebar, top to bottom: who's signed in, the inbox bar (labels as
/// inboxes, filters, new message), search, pins for the current inbox, then
/// the conversation list. Per-thread actions live on the rows.
struct ConversationListView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var inbox = model.inbox
        let rows = inbox.filtered
        let hits = inbox.isSearching ? inbox.messageHits : []
        let pins = inbox.pinnedInView
        let showPins = !pins.isEmpty && !inbox.isSearching
        VStack(spacing: 0) {
            InboxBar()
            SearchField(text: $inbox.searchText, focused: $searchFocused)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            Group {
                if rows.isEmpty && hits.isEmpty && !inbox.isLoading && !showPins && !inbox.searchingMessages {
                    ContentUnavailableView {
                        Label(emptyTitle(inbox), systemImage: inbox.filter == .unread ? "checkmark.circle" : "magnifyingglass")
                    } description: {
                        Text(inbox.searchText.isEmpty ? "Nothing matches this inbox." : (inbox.searchText.trimmingCharacters(in: .whitespaces).count < 3 ? "Type at least three characters to search inside messages." : "No conversation or message contains this."))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $inbox.sidebarSelection) {
                        if showPins {
                            PinnedGrid(pins: pins)
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
                    .listStyle(.sidebar)
                    .contentMargins(.top, 0, for: .scrollContent)
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .focused($listFocused)
                    .onKeyPress(.return) { inbox.requestFocus(.composer); return .handled }
                    .onKeyPress(.space) { inbox.requestFocus(.composer); return .handled }
                    .onKeyPress(characters: .letters, phases: .down) { press in
                        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
                        return handleKey(press.characters) ? .handled : .ignored
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
        .onAppear { listFocused = true }
        .sheet(item: Binding(get: { inbox.renamingLabel }, set: { inbox.renamingLabel = $0 })) { RenameLabelSheet(label: $0).environment(model) }
    }

    private func row(_ snap: ConversationSnapshot) -> some View {
        let inbox = model.inbox
        let id = snap.record.convId
        return ConversationRow(snapshot: snap, unreadCount: inbox.unreadCount(snap))
            .tag(id)
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
        .background(Color.primary.opacity(0.04))
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
            HStack(alignment: .center, spacing: 0) {
                Text(title(inbox.filter)).font(AFont.title).lineLimit(1).frame(height: 22)
                Spacer(minLength: 8)
                HStack(spacing: 2) {
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
                ConversationActions(convId: inbox.selectedConvId, asMenu: false)
                Button { NotificationCenter.default.post(name: .allmanCompose, object: nil) } label: { BarIcon("square.and.pencil") }
                    .buttonStyle(.plain)
                    .help("New message (⌘N)")
                    .keyboardShortcut("n", modifiers: .command)
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

    init(_ name: String, prominent: Bool = false) { self.name = name; self.prominent = prominent }

    var body: some View {
        Image(systemName: name)
            .font(AFont.icon)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(prominent ? Color.accentColor : Color.secondary)
            .frame(width: 24, height: 22)
            .contentShape(Rectangle())
    }
}

// MARK: - Search

struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var prompt = "Search people and messages"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(AFont.icon).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(AFont.body)
                .focused(focused)
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
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: r.avatarURL, name: r.displayName, size: 40)
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
                    if let m = snapshot.lastMessage {
                        Text((m.isFromMe ? "You: " : "") + m.previewText.replacingOccurrences(of: "\n", with: " "))
                            .font(AFont.secondary)
                            .foregroundStyle(unread ? .primary : .secondary)
                            .lineLimit(2)
                    } else if let h = r.headline {
                        Text(h).font(AFont.secondary).foregroundStyle(.tertiary).lineLimit(2)
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
        .overlay(alignment: .topTrailing) {
            if hovering {
                RowActions(convId: r.convId)
                    .padding(.top, 2)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// Immediate actions on a hovered row; label/snooze/note open the popovers anchored in the inbox bar.
private struct RowActions: View {
    @Environment(AppModel.self) private var model
    let convId: String

    var body: some View {
        let inbox = model.inbox
        HStack(spacing: 0) {
            btn(inbox.isPinned(convId) ? "pin.fill" : "pin", "Pin") { inbox.togglePin(convId) }
            btn("tag", "Labels") { inbox.select(convId); inbox.showLabelPicker = true }
            btn("clock", "Snooze") { inbox.select(convId); inbox.showSnoozePicker = true }
            btn("note.text", "Note") { inbox.select(convId); inbox.showNoteEditor = true }
            btn(inbox.isArchived(convId) ? "tray.and.arrow.up" : "archivebox", "Archive") { inbox.toggleArchive(convId) }
        }
        .padding(.horizontal, 4)
    }

    private func btn(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { BarIcon(icon) }
            .buttonStyle(.plain).help(help)
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
                        AvatarView(url: snap.record.avatarURL, name: snap.record.displayName, size: 56)
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
                        Text(snap.record.firstName?.isEmpty == false ? snap.record.firstName! : snap.record.displayName)
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

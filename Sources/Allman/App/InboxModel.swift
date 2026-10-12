// The inbox: conversation list + per-thread messages, read straight off the
// store and kept fresh by FSEvents. Sends/reactions shell out to the CLI.

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class InboxModel {
    /// Which inbox the sidebar shows. Every label is its own inbox; a thread can be in several.
    enum Filter: Hashable, Identifiable {
        case all, unread, needsReply, awaitingReply, firstDegree, reminders, archived
        case label(String)

        static let builtIn: [Filter] = [.all, .unread, .needsReply, .awaitingReply, .firstDegree]
        var id: String {
            if case .label(let l) = self { return "label:\(l)" }
            return symbol
        }
        var rawValue: String { title }
        var title: String {
            switch self {
            case .all: return "All"
            case .unread: return "Unread"
            case .needsReply: return "Needs my reply"
            case .awaitingReply: return "Awaiting their reply"
            case .firstDegree: return "1st-degree connections"
            case .reminders: return "Snoozed & reminders"
            case .archived: return "Archived"
            case .label: return "Label"
            }
        }
        var symbol: String {
            switch self {
            case .all: return "tray.full"
            case .unread: return "envelope.badge"
            case .needsReply: return "arrowshape.turn.up.left"
            case .awaitingReply: return "paperplane"
            case .firstDegree: return "person.2"
            case .reminders: return "clock.badge"
            case .archived: return "archivebox"
            case .label: return "tag"
            }
        }
        var isLabel: Bool { if case .label = self { return true } else { return false } }
    }

    private(set) var snapshots: [ConversationSnapshot] = []
    private(set) var byId: [String: ConversationSnapshot] = [:]
    private(set) var messages: [String: [Message]] = [:]
    /// Downloaded attachments per conversation (see StoreReader.mediaFiles).
    private(set) var media: [String: [String: URL]] = [:]
    private(set) var mediaLoading: Set<String> = []
    private(set) var isLoading = false
    private(set) var loadingThread: Set<String> = []
    private(set) var backfilling: Set<String> = []
    var readState: ReadState { didSet { recompute() } }
    /// Labels, notes, snoozes, archive — app-owned, per account.
    var organizer: Organizer { didSet { recompute() } }
    var selectedConvId: String? { didSet { recompute() } }
    var searchText = "" { didSet { recompute(); scheduleMessageSearch() } }
    var filter: Filter = .all {
        didSet {
            // A thread that isn't in the new inbox must not stay open as if it were.
            if let id = selectedConvId, let snap = byId[id], !belongs(snap, to: filter) { select(nil) }
            recompute()
        }
    }
    /// Full-text hits across every stored message for the current search (3+ chars).
    private(set) var messageHits: [MessageHit] = []
    private(set) var searchingMessages = false
    private var searchTask: Task<Void, Never>?
    /// The message-hit row highlighted in the sidebar, if the selection came from one.
    private(set) var selectedHitId: String?
    /// A message the open thread should scroll to and flash. `token` re-fires for repeats.
    struct ScrollTarget: Equatable { let convId: String; let urn: String; let token: Int }
    private(set) var scrollTarget: ScrollTarget?
    /// Derived, recomputed only when inputs change — cheap to read from views.
    private(set) var filtered: [ConversationSnapshot] = []
    private(set) var unread: [ConversationSnapshot] = []
    private(set) var unreadCount = 0
    /// Pinned conversations in pin order (only those that still exist).
    private(set) var pinnedSnapshots: [ConversationSnapshot] = []
    /// The pins that belong to the inbox on screen (All, or a label).
    private(set) var pinnedInView: [ConversationSnapshot] = []

    enum FocusTarget { case list, composer, search }
    /// Views observe this to move keyboard focus; bump `focusToken` to re-fire.
    private(set) var focusTarget: FocusTarget = .list
    private(set) var focusToken = 0
    func requestFocus(_ target: FocusTarget) { focusTarget = target; focusToken += 1 }
    var isSending = false
    var composerError: String?
    var toast: String?

    /// Called with inbound messages that appeared since the previous snapshot set.
    var onNewInbound: (([(ConversationSnapshot, Message)]) -> Void)?

    private let reader: StoreReader
    private(set) var accountDir: URL?
    private var context: AllmanRunner.Context?
    private var watcher: StoreWatcher?
    private var backfilled: Set<String> = []
    private var reloadGeneration = 0

    init(reader: StoreReader, readState: ReadState = ReadState.load(), organizer: Organizer = Organizer()) {
        self.reader = reader
        self.readState = readState
        self.organizer = organizer
    }

    // MARK: Derived

    private func recompute() {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let now = Date()
        // Archived and snoozed threads are out of the way everywhere except their own views and search.
        let tucked: (ConversationSnapshot) -> Bool = { [organizer] in organizer.isArchived($0) || organizer.isSnoozed($0, now: now) }
        unread = snapshots.filter { readState.isUnread($0) && !tucked($0) }
        unreadCount = unread.count
        pinnedSnapshots = readState.pins.compactMap { byId[$0] }
        // Pins stay whatever the filter; a label inbox shows only its own members.
        pinnedInView = pinnedSnapshots.filter { snap in
            if case .label(let id) = filter { return organizer.has(label: id, snap.record.convId) }
            return true
        }
        let pinSet = Set(pinnedInView.map(\.record.convId))
        let browsing = q.isEmpty
        var scores: [String: Int] = [:]
        filtered = snapshots.filter { snap in
            // Pinned threads live in the grid while browsing; searching/filtering shows them in the list.
            // Pinned threads live in the grid while browsing, never in the list as well.
            if browsing && pinSet.contains(snap.record.convId) { return false }
            if snap.record.convId == selectedConvId { return q.isEmpty || matches(snap, q) }
            if !(q.isEmpty ? belongs(snap, to: filter, now: now) : belongsWhileSearching(snap, to: filter, now: now)) { return false }
            if q.isEmpty { return true }
            let score = rank(snap, q)
            if score > 0 { scores[snap.record.convId] = score }
            return score > 0
        }
        if !q.isEmpty {
            // Relevance first (prefix/whole-word over substring), recency as the tiebreak.
            filtered.sort { (scores[$0.record.convId] ?? 0, $0.activityDate) > (scores[$1.record.convId] ?? 0, $1.activityDate) }
        }
        if case .reminders = filter {
            // Soonest due first; the list is otherwise newest-activity first.
            filtered.sort { (organizer.snooze($0.record.convId)?.until ?? .distantFuture) < (organizer.snooze($1.record.convId)?.until ?? .distantFuture) }
        }
    }

    // MARK: Labels / notes / snooze / archive

    /// Last organizer action, so the toast can offer Undo.
    var undo: (title: String, action: () -> Void)?
    /// Popovers on the open thread, so menu commands and keys can open them.
    var showLabelPicker = false
    var showSnoozePicker = false
    var showNoteEditor = false
    var showSnippetPicker = false
    var renamingLabel: InboxLabel?
    /// New Message mode: the sidebar search becomes a people search.
    var composing = false { didSet { if composing { composeQuery = "" } } }
    var composeQuery = ""
    /// A popover opened from a row's own action button (anchored there, not at the bar).
    enum RowAction: Equatable { case label, snooze, note }
    struct RowPopover: Equatable { let convId: String; let kind: RowAction }
    var rowPopover: RowPopover?
    /// Dev snapshots: bumped after VoiceRecorder.debugState changes so composers re-sync.
    var voiceDebugTick = 0

    func unreadCount(label id: String) -> Int {
        snapshots.filter { organizer.has(label: id, $0.record.convId) && readState.isUnread($0) && !organizer.isArchived($0) }.count
    }
    var dueCount: Int { organizer.snoozes.filter { $0.value.until <= Date() }.count }

    private func showUndo(_ text: String, _ title: String, _ action: @escaping () -> Void) {
        undo = (title, action)
        toast = text
    }

    func toggle(label id: String, _ convId: String) {
        organizer.toggle(label: id, convId)
        organizer.save()
    }

    @discardableResult
    func addLabel(_ name: String, icon: String? = nil, to convId: String? = nil) -> InboxLabel? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let l = organizer.addLabel(name: trimmed, icon: icon)
        if let convId, !organizer.has(label: l.id, convId) { organizer.toggle(label: l.id, convId) }
        organizer.save()
        return l
    }

    func rename(label id: String, to name: String, icon: String? = nil) {
        organizer.rename(label: id, to: name, icon: icon)
        organizer.save()
    }

    func deleteLabel(_ id: String) {
        organizer.deleteLabel(id)
        organizer.save()
        if filter == .label(id) { filter = .all }
    }

    func setNote(_ text: String, _ convId: String) {
        guard organizer.note(convId) != text else { return }
        organizer.setNote(text, convId)
        organizer.save()
    }

    func archive(_ convId: String) {
        guard let snap = byId[convId] else { return }
        organizer.archive(snap)
        organizer.save()
        if selectedConvId == convId, filter != .archived { selectNeighborOrNone(of: convId) }
        showUndo("Archived \(snap.record.displayName)", "Undo") { [weak self] in self?.unarchive(convId) }
    }

    func toggleArchive(_ convId: String) {
        if isArchived(convId) { unarchive(convId) } else { archive(convId) }
    }

    func unarchive(_ convId: String) {
        organizer.unarchive(convId)
        organizer.save()
    }

    func isArchived(_ convId: String) -> Bool { byId[convId].map { organizer.isArchived($0) } ?? false }

    func snooze(_ convId: String, until: Date, hidden: Bool, note: String? = nil) {
        guard let snap = byId[convId] else { return }
        let previous = organizer.snooze(convId)
        organizer.setSnooze(snap, until: until, hidden: hidden, note: note)
        organizer.save()
        if hidden, selectedConvId == convId, filter != .reminders { selectNeighborOrNone(of: convId) }
        let when = Fmt.reminderTime(until)
        showUndo(hidden ? "Snoozed until \(when)" : "Reminder set for \(when)", "Undo") { [weak self] in
            guard let self else { return }
            if let previous { self.organizer.snoozes[convId] = previous } else { self.organizer.clearSnooze(convId) }
            self.organizer.save()
        }
    }

    func clearSnooze(_ convId: String) {
        organizer.clearSnooze(convId)
        organizer.save()
    }

    /// After tucking the open thread away, move to the next row so the pane isn't left empty.
    private func selectNeighborOrNone(of convId: String) {
        let rows = navigationOrder
        if let i = rows.firstIndex(where: { $0.record.convId == convId }) {
            let next = rows.indices.contains(i + 1) ? rows[i + 1] : (i > 0 ? rows[i - 1] : nil)
            select(next?.record.convId)
        } else {
            select(nil)
        }
    }

    /// Fired by a minute timer: due reminders ping once and come back into the inbox.
    var onReminderDue: ((ConversationSnapshot, Snooze) -> Void)?
    private var reminderTimer: Task<Void, Never>?

    private func startReminderClock() {
        reminderTimer?.cancel()
        reminderTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.fireDueReminders()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func fireDueReminders() {
        let due = organizer.takeDue()
        guard !due.isEmpty else { recompute(); return }
        organizer.save()
        for id in due {
            if let snap = byId[id], let s = organizer.snooze(id) { onReminderDue?(snap, s) }
        }
    }

    /// Membership in an inbox view (archived/snoozed threads are tucked away except in their own views).
    func belongs(_ snap: ConversationSnapshot, to filter: Filter, now: Date = Date()) -> Bool {
        let tucked = organizer.isArchived(snap) || organizer.isSnoozed(snap, now: now)
        switch filter {
        case .all: return !tucked
        case .unread: return readState.isUnread(snap) && !tucked
        // A reaction of yours on their last message counts as a reply.
        case .needsReply: return snap.lastMessage.map { !$0.isFromMe && !$0.reactions.contains { $0.hasUserReacted } } == true && !tucked
        case .awaitingReply: return snap.lastMessage?.isFromMe == true && !tucked
        case .firstDegree: return snap.record.distance == "DISTANCE_1" && !tucked
        case .reminders: return organizer.snooze(snap.record.convId) != nil
        case .archived: return organizer.isArchived(snap)
        case .label(let id): return organizer.has(label: id, snap.record.convId) && !organizer.isArchived(snap)
        }
    }

    /// While searching, All also surfaces tucked-away threads.
    private func belongsWhileSearching(_ snap: ConversationSnapshot, to filter: Filter, now: Date) -> Bool {
        if filter == .all { return true }
        return belongs(snap, to: filter, now: now)
    }

    private func matches(_ snap: ConversationSnapshot, _ q: String) -> Bool { rank(snap, q) > 0 }

    /// Name outranks handle/headline/company, which outrank the last message.
    private func rank(_ snap: ConversationSnapshot, _ q: String) -> Int {
        let r = snap.record
        let conn = connection(for: r)
        return SearchRank.score(name: r.displayName, secondary: [r.slug, r.headline, conn?.company, conn?.title], tertiary: [snap.lastMessage?.body], query: q)
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Debounced `grep`-style scan of every thread; runs off the main thread.
    private func scheduleMessageSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3, let dir = accountDir else {
            messageHits = []; searchingMessages = false
            return
        }
        searchingMessages = true
        let reader = self.reader
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) {
                reader.searchMessages(accountDir: dir, query: q, isCancelled: { Task.isCancelled })
            }.value
            guard !Task.isCancelled else { return }
            messageHits = hits
            searchingMessages = false
        }
    }

    /// Open the thread a search hit belongs to and jump to that message.
    func open(hit: MessageHit) {
        select(hit.convId)
        selectedHitId = hit.id
        scrollTarget = ScrollTarget(convId: hit.convId, urn: hit.message.urn, token: (scrollTarget?.token ?? 0) + 1)
    }

    /// Sidebar selection: a conversation id or a message-hit id ("msg:…").
    var sidebarSelection: String? {
        get {
            if let hit = selectedHitId { return hit }
            // A pinned thread lives in the grid, not the list: the list holds no selection for it.
            guard let id = selectedConvId, filtered.contains(where: { $0.record.convId == id }) else { return nil }
            return id
        }
        set {
            if let id = newValue, id.hasPrefix("msg:") {
                if let hit = messageHits.first(where: { $0.id == id }) { open(hit: hit) }
            } else if newValue == nil, let id = selectedConvId, !filtered.contains(where: { $0.record.convId == id }) {
                // The list dropping a selection it never showed (pinned-only) is not a deselect.
                return
            } else {
                select(newValue)
            }
        }
    }

    func consumeScrollTarget() { scrollTarget = nil }

    var selected: ConversationSnapshot? { selectedConvId.flatMap { byId[$0] } }
    func isUnread(_ snap: ConversationSnapshot) -> Bool { readState.isUnread(snap) }
    func unreadCount(_ snap: ConversationSnapshot) -> Int { readState.unreadCount(snap) }

    // MARK: Loading

    func attach(account: Account, context: AllmanRunner.Context) async {
        self.context = context
        guard accountDir != account.dir else { return }
        accountDir = account.dir
        watcher?.stop()
        snapshots = []; byId = [:]; messages = [:]
        messageHits = []; selectedHitId = nil
        await reloadAll()
        scheduleMessageSearch()
        let w = StoreWatcher(accountDir: account.dir) { [weak self] change in
            guard let self else { return }
            Task { @MainActor in
                if change.structural { await self.reloadAll() } else if !change.convIds.isEmpty { await self.reload(convIds: change.convIds) }
                if change.connectionsChanged { self.scheduleConnectionsReload() }
            }
        }
        w.start()
        watcher = w
        loadConnectionsIfNeeded()
        startReminderClock()
    }

    func detach() {
        watcher?.stop(); watcher = nil
        reminderTimer?.cancel(); reminderTimer = nil
        accountDir = nil
        snapshots = []; byId = [:]; messages = [:]
    }

    func reloadAll() async {
        guard let dir = accountDir else { return }
        isLoading = snapshots.isEmpty
        reloadGeneration += 1
        let gen = reloadGeneration
        let reader = self.reader
        let loaded = await Task.detached(priority: .userInitiated) { reader.loadAll(accountDir: dir) }.value
        guard gen == reloadGeneration else { return }
        apply(loaded, replacingAll: true)
        isLoading = false
    }

    func reload(convIds: Set<String>) async {
        guard let dir = accountDir else { return }
        let reader = self.reader
        let ids = Array(convIds)
        let loaded = await Task.detached(priority: .userInitiated) { ids.compactMap { reader.loadSnapshot(accountDir: dir, convId: $0) } }.value
        apply(loaded, replacingAll: false)
        // Refresh any open thread that changed.
        for id in convIds where messages[id] != nil || id == selectedConvId {
            await loadMessages(convId: id, force: true)
        }
        if let sel = selectedConvId, convIds.contains(sel), let snap = byId[sel], let last = snap.lastMessage, !last.isFromMe, isWindowFocused {
            markSeen(sel)
        }
    }

    /// Set by the inbox window so a thread open on screen auto-marks new messages seen.
    var isWindowFocused = false

    private func apply(_ loaded: [ConversationSnapshot], replacingAll: Bool) {
        let old = byId
        var next = replacingAll ? [:] : byId
        for snap in loaded { next[snap.record.convId] = snap }
        byId = next
        snapshots = next.values.sorted { $0.activityDate > $1.activityDate }
        recompute()

        // Diff for notifications — only when we already had a snapshot set.
        guard !old.isEmpty else { return }
        var fresh: [(ConversationSnapshot, Message)] = []
        for snap in loaded {
            guard let last = snap.lastMessage, !last.isFromMe else { continue }
            let prev = old[snap.record.convId]?.lastMessage?.timestamp ?? 0
            if last.timestamp > prev && readState.isUnread(snap) { fresh.append((snap, last)) }
        }
        if !fresh.isEmpty { onNewInbound?(fresh) }
    }

    func loadMessages(convId: String, force: Bool = false) async {
        guard let dir = accountDir else { return }
        if !force, messages[convId] != nil { return }
        loadingThread.insert(convId)
        let reader = self.reader
        let (msgs, files) = await Task.detached(priority: .userInitiated) {
            (reader.readMessages(accountDir: dir, convId: convId), reader.mediaFiles(accountDir: dir, convId: convId))
        }.value
        // Only publish when something changed: a re-sync that rewrote identical
        // content must not churn the thread view (it can flash blank mid-layout).
        if messages[convId] != msgs { messages[convId] = msgs }
        if media[convId] != files { media[convId] = files }
        loadingThread.remove(convId)
        reconcileOutgoing(convId, with: msgs)
        ensureMedia(convId, messages: msgs, files: files)
    }

    /// The CLI writes the sent message to disk before its process exits, and the
    /// file watcher reloads it. Drop the placeholder the moment its stored copy
    /// is on screen, so the two never show together.
    private func reconcileOutgoing(_ convId: String, with msgs: [Message]) {
        guard let items = outgoing[convId], !items.isEmpty else { return }
        let keep = items.filter { item in
            if case .failed = item.state { return true }
            let since = Int64(item.createdAt.timeIntervalSince1970 * 1000) - 120_000
            let stored = msgs.contains { m in
                guard m.isFromMe, m.timestamp >= since else { return false }
                if item.audioURL != nil { return m.attachments.contains { $0.type == "voice" || $0.type == "audio" } }
                return m.body.trimmingCharacters(in: .whitespacesAndNewlines) == item.body
            }
            return !stored
        }
        if keep.count != items.count { withAnimation(nil) { outgoing[convId] = keep } }
    }

    private static let downloadable: Set<String> = ["image", "gif", "file", "audio", "voice", "video"]
    private var mediaFetched: Set<String> = []

    /// `allman media <conv>` when any attachment lacks a local file. Once per thread per session.
    private func ensureMedia(_ convId: String, messages: [Message], files: [String: URL]) {
        guard let ctx = context, let dir = accountDir, !mediaFetched.contains(convId) else { return }
        let missing = messages.contains { m in
            m.attachments.enumerated().contains { i, a in
                Self.downloadable.contains(a.type ?? "") && files[StoreReader.mediaKey(messageUrn: m.urn, index: i)] == nil
            }
        }
        guard missing else { return }
        mediaFetched.insert(convId)
        mediaLoading.insert(convId)
        let reader = self.reader
        Task { @MainActor in
            defer { mediaLoading.remove(convId) }
            _ = try? await AllmanRunner.runWithRetry(["media", convId, "--json", "--limit", "200"], context: ctx, timeout: 300, attempts: 2)
            media[convId] = await Task.detached { reader.mediaFiles(accountDir: dir, convId: convId) }.value
        }
    }

    func mediaURL(convId: String, message: Message, index: Int) -> URL? {
        media[convId]?[StoreReader.mediaKey(messageUrn: message.urn, index: index)]
    }

    // MARK: Pins

    func isPinned(_ convId: String) -> Bool { readState.isPinned(convId) }
    var canPinMore: Bool { readState.pins.count < ReadState.maxPins }

    func togglePin(_ convId: String) {
        readState.togglePin(convId)
        readState.save()
    }

    func movePin(_ convId: String, to index: Int) {
        readState.movePin(convId, to: index)
        readState.save()
    }

    // MARK: Keyboard navigation

    /// The rows the arrow keys walk: pinned first (grid order), then the list.
    var navigationOrder: [ConversationSnapshot] {
        let browsing = searchText.trimmingCharacters(in: .whitespaces).isEmpty && (filter == .all || filter.isLabel)
        let pinned = Set(pinnedInView.map(\.record.convId))
        return browsing ? pinnedInView + filtered.filter { !pinned.contains($0.record.convId) } : filtered
    }

    func selectNext(unreadOnly: Bool = false) { step(1, unreadOnly: unreadOnly) }
    func selectPrevious(unreadOnly: Bool = false) { step(-1, unreadOnly: unreadOnly) }

    private func step(_ delta: Int, unreadOnly: Bool) {
        let rows = navigationOrder
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.record.convId == selectedConvId }
        var i = current.map { $0 + delta } ?? (delta > 0 ? 0 : rows.count - 1)
        while i >= 0, i < rows.count {
            if !unreadOnly || readState.isUnread(rows[i]) { select(rows[i].record.convId, reveal: true); return }
            i += delta
        }
        if unreadOnly, let first = (delta > 0 ? rows : rows.reversed()).first(where: { readState.isUnread($0) }) {
            select(first.record.convId, reveal: true) // wrap around
        }
    }

    // MARK: Selection / read state

    /// Bumped when a selection was made by the keyboard, a menu, a notification or a
    /// draft — anything that isn't a click on a visible row — so the list scrolls to it.
    private(set) var revealToken = 0
    private(set) var revealId: String?
    private(set) var revealAt = Date.distantPast
    func requestReveal(_ convId: String) { revealId = convId; revealAt = Date(); revealToken += 1 }

    func select(_ convId: String?, reveal: Bool = false) {
        if convId != nil, draft != nil { draft = nil }
        selectedHitId = nil
        selectedConvId = convId
        if reveal, let convId { requestReveal(convId) }
        composerError = nil
        guard let convId else { return }
        Task { await loadMessages(convId: convId) }
        markSeen(convId)
        backfillIfNeeded(convId)
        refreshRecent(convId)
    }

    private var refreshedAt: [String: Date] = [:]

    /// `allman sync <conv> --limit 20` re-upserts the newest page, which is how
    /// reactions added or removed on linkedin.com reach the store. Throttled.
    func refreshRecent(_ convId: String, force: Bool = false) {
        guard let ctx = context, byId[convId] != nil else { return }
        if !force, let t = refreshedAt[convId], Date().timeIntervalSince(t) < 120 { return }
        refreshedAt[convId] = Date()
        Task { @MainActor in
            _ = try? await AllmanRunner.runWithRetry(["sync", convId, "--json", "--limit", "20"], context: ctx, timeout: 120, attempts: 2)
        }
    }

    func markSeen(_ convId: String) {
        guard let snap = byId[convId] else { return }
        let wasUnread = readState.isUnread(snap)
        let ts = snap.lastMessage?.timestamp ?? Int64(Date().timeIntervalSince1970 * 1000)
        readState.markSeen(convId, at: max(ts, Int64(Date().timeIntervalSince1970 * 1000)))
        readState.save()
        // Mirror to linkedin.com through the CLI whenever LinkedIn still thinks it's unread.
        let linkedInUnread = (snap.record.unreadCount ?? 0) > 0 || snap.record.read == false
        if wasUnread || linkedInUnread { markReadOnLinkedIn(snap) }
    }

    func markAllSeen() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let targets = snapshots.filter { readState.isUnread($0) }
        for snap in targets { readState.markSeen(snap.record.convId, at: now) }
        readState.save()
        for snap in targets { markReadOnLinkedIn(snap) }
    }

    private var markReadInFlight: Set<String> = []

    /// `allman read <target>` — the CLI owns the LinkedIn call and updates RECORD.json.
    private func markReadOnLinkedIn(_ snap: ConversationSnapshot) {
        guard let ctx = context else { return }
        let convId = snap.record.convId
        guard !markReadInFlight.contains(convId) else { return }
        markReadInFlight.insert(convId)
        Task { @MainActor in
            defer { markReadInFlight.remove(convId) }
            do {
                _ = try await AllmanRunner.runWithRetry(["read", snap.record.sendTarget, "--json"], context: ctx, timeout: 30)
            } catch let err as AllmanError where err.stderr.contains("unknown command") {
                toast = "Update the allman CLI to sync read state to LinkedIn."
            } catch {
                cliLog.error("mark read failed for \(convId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Writes (through the CLI)

    /// Message being replied to (LinkedIn "reply" quoting), per conversation.
    var replyingTo: [String: Message] = [:]

    /// A message the user just sent, shown in the thread right away (iMessage
    /// style) while `allman send` runs; replaced by the stored message on success.
    struct OutgoingMessage: Identifiable, Equatable {
        enum State: Equatable { case sending, failed(String) }
        let id: String
        let convId: String
        let body: String
        let createdAt: Date
        let replyTo: Message?
        var state: State = .sending
        /// A voice note being sent: the local recording and its length.
        var audioURL: URL? = nil
        var audioDurationMs: Int? = nil

        /// What the thread renders: a from-me message carrying the quote if any.
        var asMessage: Message {
            var attachments: [Attachment] = []
            if let r = replyTo {
                attachments.append(Attachment(replyingTo: r))
            }
            if audioURL != nil {
                attachments.append(Attachment(type: "voice", url: nil, name: audioURL?.lastPathComponent, size: nil, mimeType: "audio/mp4", previewUrl: nil, width: nil, height: nil, durationMs: audioDurationMs, title: nil, description: nil, originalText: nil, authorName: nil))
            }
            return Message(urn: "outgoing:\(id)", timestamp: Int64(createdAt.timeIntervalSince1970 * 1000), fromUrn: nil, fromName: nil, isFromMe: true, body: body, reactions: [], attachments: attachments, originToken: nil, subject: nil)
        }

        /// Media the thread can render for the placeholder (the local recording).
        var localMedia: [String: URL] {
            guard let audioURL else { return [:] }
            return [StoreReader.mediaKey(messageUrn: "outgoing:\(id)", index: replyTo == nil ? 0 : 1): audioURL]
        }
    }
    /// In-flight and failed sends per conversation, oldest first.
    private(set) var outgoing: [String: [OutgoingMessage]] = [:]
    func outgoingMessages(_ convId: String) -> [OutgoingMessage] { outgoing[convId] ?? [] }

    func retry(_ id: String, in convId: String) {
        guard let item = outgoing[convId]?.first(where: { $0.id == id }) else { return }
        withAnimation { outgoing[convId]?.removeAll { $0.id == id } }
        if let url = item.audioURL, let ms = item.audioDurationMs {
            Task { _ = await sendAudio(url, durationMs: ms, to: convId) }
            return
        }
        if let r = item.replyTo { replyingTo[convId] = r }
        Task { _ = await send(item.body, to: convId) }
    }

    /// Dev snapshots only: render the in-flight and failed states without sending anything.
    func debugInjectOutgoing(_ convId: String) {
        withAnimation(.spring(duration: 0.35)) { outgoing[convId] = [ 
            OutgoingMessage(id: "dbg-1", convId: convId, body: "On my way — see you at 5!", createdAt: Date(), replyTo: nil, state: .sending),
            OutgoingMessage(id: "dbg-2", convId: convId, body: "Also, can you forward the deck?", createdAt: Date(), replyTo: nil, state: .failed("New messages arrived in this thread — read them, then try again.")),
        ] }
    }

    func discardOutgoing(_ id: String, in convId: String) {
        withAnimation { outgoing[convId]?.removeAll { $0.id == id } }
    }

    // MARK: Compose

    private(set) var connections: [Connection] = []
    private(set) var connectionsBySlug: [String: Connection] = [:]
    private(set) var connectionsById: [String: Connection] = [:]
    private var connectionsLoaded = false
    private var connectionsReloadScheduled = false
    /// A recipient with no local thread yet; shown in place of the selected conversation.
    var draft: DraftRecipient? { didSet { if draft == nil { draftOthers = [] }; recompute() } }
    /// Further recipients of the draft: more than one makes it a new group thread.
    var draftOthers: [DraftRecipient] = [] { didSet { recompute() } }
    var draftRecipients: [DraftRecipient] { (draft.map { [$0] } ?? []) + draftOthers }

    /// Another person for the open draft (starts one when none is open).
    func addDraftRecipient(_ r: DraftRecipient) {
        guard let first = draft else { startDraft(r); return }
        guard first.slug != r.slug, !draftOthers.contains(where: { $0.slug == r.slug }) else { return }
        draftOthers.append(r)
    }

    func removeDraftRecipient(_ slug: String) {
        if draft?.slug == slug {
            let rest = draftOthers
            draft = rest.first
            draftOthers = Array(rest.dropFirst())
        } else {
            draftOthers.removeAll { $0.slug == slug }
        }
    }

    func loadConnectionsIfNeeded() {
        guard !connectionsLoaded else { return }
        connectionsLoaded = true
        Task { await reloadConnections() }
    }

    /// `connections/` is ~10k files; read it off the main thread.
    func reloadConnections() async {
        guard let dir = accountDir else { return }
        let reader = self.reader
        let loaded = await Task.detached(priority: .utility) { reader.loadConnections(accountDir: dir) }.value
        guard accountDir == dir else { return }
        connections = loaded
        var bySlug: [String: Connection] = [:], byId: [String: Connection] = [:]
        for c in loaded { if let s = c.slug { bySlug[s] = c }; byId[c.flagshipId] = c }
        connectionsBySlug = bySlug
        connectionsById = byId
    }

    /// `allman enrich` / `connect` write one file at a time; coalesce into one reload.
    private func scheduleConnectionsReload() {
        guard !connectionsReloadScheduled else { return }
        connectionsReloadScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            connectionsReloadScheduled = false
            await reloadConnections()
        }
    }

    /// The stored connection behind a conversation, when the person is a 1st-degree contact.
    func connection(for record: ConversationRecord) -> Connection? {
        if let s = record.slug, let c = connectionsBySlug[s] { return c }
        if let p = record.profileId, let c = connectionsById[p] { return c }
        return nil
    }

    /// Who is being fetched by `allman enrich` right now (slugs).
    private(set) var enriching: Set<String> = []

    /// `allman enrich <slug> --deep`: title, company, location, about, history. One
    /// person, 4 requests, charged against the CLI's enrichment quota.
    func enrich(slug: String, force: Bool = false) {
        guard let ctx = context, !enriching.contains(slug) else { return }
        enriching.insert(slug)
        Task { @MainActor in
            defer { enriching.remove(slug) }
            var args = ["enrich", slug, "--deep", "--json"]
            if force { args.append("--force") }
            do {
                _ = try await AllmanRunner.run(args, context: ctx, timeout: 180)
                await reloadConnections()
                toast = "Profile details updated"
            } catch let err as AllmanError {
                let s = err.stderr.lowercased()
                if s.contains("quota") || s.contains("capacity") {
                    toast = "Enrichment quota reached — the CLI will allow more later."
                } else if s.contains("unknown command") {
                    toast = "Fetching profile details needs a newer allman CLI."
                } else {
                    toast = "Couldn't fetch profile details: \(err.friendlyMessage)"
                }
            } catch {
                toast = "Couldn't fetch profile details: \(error.localizedDescription)"
            }
        }
    }

    func startDraft(_ recipient: DraftRecipient) {
        // Reuse an existing thread when the slug already has one.
        if let existing = snapshots.first(where: { $0.record.slug == recipient.slug }) {
            draft = nil
            composing = false
            select(existing.record.convId, reveal: true)
            return
        }
        selectedConvId = nil
        draft = recipient
    }

    /// `allman people <query> --json`: LinkedIn people search through the CLI.
    func searchPeople(_ query: String) async throws -> [PersonHit] {
        guard let ctx = context else { return [] }
        return try await AllmanRunner.runJSON(["people", query, "--limit", "8", "--json"], as: [PersonHit].self, context: ctx, timeout: 30)
    }

    func send(_ text: String, to convId: String? = nil) async -> Bool {
        let target = convId ?? selectedConvId
        guard let target, let ctx = context else { return false }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        if target.hasPrefix("draft:") { return await sendDraft(body, context: ctx) }
        guard let snap = byId[target] else { return false }

        // Show it in the thread immediately; the CLI call runs behind it.
        let reply = replyingTo[target]
        replyingTo[target] = nil
        let item = OutgoingMessage(id: UUID().uuidString, convId: target, body: body, createdAt: Date(), replyTo: reply)
        withAnimation(.spring(duration: 0.35)) { outgoing[target, default: []].append(item) }
        isSending = true
        composerError = nil
        defer { isSending = !outgoing.values.allSatisfy { $0.allSatisfy { if case .failed = $0.state { return true } else { return false } } } }

        var args = ["send", snap.record.sendTarget, body, "--json"]
        if let reply { args += ["--reply-to", reply.urn] }
        do {
            _ = try await AllmanRunner.runJSON(args, as: SendResult.self, context: ctx, timeout: 60)
            await reload(convIds: [target])
            // The stored copy is on screen now; drop the placeholder without a flash.
            withAnimation(nil) { outgoing[target]?.removeAll { $0.id == item.id } }
            markSeen(target)
            return true
        } catch {
            let reason: String
            if let err = error as? AllmanError {
                // The CLI aborts when new inbound messages arrived since the last sync.
                if err.stderr.contains("received before send") {
                    reason = "New messages arrived in this thread — read them, then try again."
                    await reload(convIds: [target])
                } else if err.stderr.contains("unknown option") && err.stderr.contains("reply-to") {
                    reason = "Replying to a specific message needs a newer allman CLI."
                } else {
                    reason = err.friendlyMessage
                }
            } else {
                reason = error.localizedDescription
            }
            if let i = outgoing[target]?.firstIndex(where: { $0.id == item.id }) {
                outgoing[target]?[i].state = .failed(reason)
            }
            composerError = nil
            return false
        }
    }

    /// A recorded voice note, through `allman send <target> --audio <file>`.
    func sendAudio(_ fileURL: URL, durationMs: Int, to convId: String? = nil) async -> Bool {
        let target = convId ?? selectedConvId
        guard let target, let ctx = context, let snap = byId[target] else { return false }
        var item = OutgoingMessage(id: UUID().uuidString, convId: target, body: "", createdAt: Date(), replyTo: nil)
        item.audioURL = fileURL
        item.audioDurationMs = durationMs
        withAnimation(.spring(duration: 0.35)) { outgoing[target, default: []].append(item) }
        isSending = true
        defer { isSending = !outgoing.values.allSatisfy { $0.allSatisfy { if case .failed = $0.state { return true } else { return false } } } }
        let args = ["send", snap.record.sendTarget, "--audio", fileURL.path, "--duration-ms", String(durationMs), "--json"]
        do {
            _ = try await AllmanRunner.runJSON(args, as: SendResult.self, context: ctx, timeout: 180)
            await reload(convIds: [target])
            await loadMessages(convId: target, force: true)
            withAnimation(nil) { outgoing[target]?.removeAll { $0.id == item.id } }
            markSeen(target)
            return true
        } catch {
            let reason: String
            if let err = error as? AllmanError {
                if err.stderr.contains("unknown option") && err.stderr.contains("audio") {
                    reason = "Sending voice notes needs a newer allman CLI (send --audio)."
                } else if err.stderr.contains("received before send") {
                    reason = "New messages arrived in this thread — read them, then try again."
                    await reload(convIds: [target])
                } else {
                    reason = err.friendlyMessage
                }
            } else {
                reason = error.localizedDescription
            }
            if let i = outgoing[target]?.firstIndex(where: { $0.id == item.id }) { outgoing[target]?[i].state = .failed(reason) }
            return false
        }
    }

    /// First message to someone without a local thread. The CLI resolves the
    /// profile, finds or creates the LinkedIn thread, and writes the record.
    private func sendDraft(_ body: String, context ctx: AllmanRunner.Context) async -> Bool {
        guard let recipient = draft else { return false }
        let recipients = draftRecipients
        isSending = true
        composerError = nil
        defer { isSending = false }
        do {
            // Several recipients: the CLI creates a group thread (allman send a,b,c).
            let target = recipients.map(\.slug).joined(separator: ",")
            let result = try await AllmanRunner.runJSON(["send", target, body, "--json"], as: SendResult.self, context: ctx, timeout: 90)
            let convUrn = result.conversationUrn ?? ""
            let bare = Self.bareConversationId(convUrn)
            await reloadAll()
            draft = nil
            if let bare, byId[bare] != nil {
                select(bare, reveal: true)
            } else if recipients.count == 1, let found = snapshots.first(where: { $0.record.slug == recipient.slug }) {
                select(found.record.convId, reveal: true)
            } else if recipients.count > 1 {
                let slugs = Set(recipients.map(\.slug))
                if let found = snapshots.first(where: { $0.record.isGroupThread && slugs.isSubset(of: Set($0.record.members.compactMap(\.slug))) }) { select(found.record.convId, reveal: true) }
            }
            toast = recipients.count > 1 ? "Sent to \(recipients.count) people" : "Sent to \(recipient.name)"
            return true
        } catch let err as AllmanError {
            if err.stderr.contains("not found on LinkedIn") {
                composerError = "LinkedIn couldn't find a profile at linkedin.com/in/\(recipient.slug)."
            } else {
                composerError = err.friendlyMessage
            }
            return false
        } catch {
            composerError = error.localizedDescription
            return false
        }
    }

    /// `urn:li:messagingThread:2-abc` / `urn:li:msg_conversation:(…,2-abc)` → `2-abc`.
    static func bareConversationId(_ urn: String) -> String? {
        guard !urn.isEmpty else { return nil }
        if let comma = urn.lastIndex(of: ",") { return String(urn[urn.index(after: comma)...]).replacingOccurrences(of: ")", with: "") }
        if let colon = urn.lastIndex(of: ":") { return String(urn[urn.index(after: colon)...]) }
        return urn
    }

    func react(_ message: Message, in convId: String, emoji: String) async {
        guard let snap = byId[convId], let ctx = context else { return }
        let already = message.reactions.contains { $0.emoji == emoji && $0.hasUserReacted }
        var args = ["react", snap.record.sendTarget, emoji, "--message", message.urn, "--json"]
        if already { args.append("--unreact") }
        do {
            _ = try await AllmanRunner.runJSON(args, as: ReactResult.self, context: ctx, timeout: 30)
            await loadMessages(convId: convId, force: true)
        } catch let err as AllmanError {
            toast = err.isGitLock ? "Couldn't save the reaction — the store was busy. Try again." : "Reaction failed: \(err.friendlyMessage)"
        } catch {
            toast = "Reaction failed: \(error.localizedDescription)"
        }
    }

    /// Walk a thread back to its first message the first time it's opened.
    func backfillIfNeeded(_ convId: String) {
        guard let snap = byId[convId], let ctx = context else { return }
        guard snap.record.syncState?.fullyBackfilled != true, !backfilled.contains(convId) else { return }
        backfilled.insert(convId)
        backfilling.insert(convId)
        Task { @MainActor in
            defer { backfilling.remove(convId) }
            do {
                _ = try await AllmanRunner.runWithRetry(["sync", convId, "--json"], context: ctx, timeout: 600, attempts: 2)
            } catch {
                // Non-fatal: the thread still shows whatever is on disk.
            }
            await reload(convIds: [convId])
        }
    }

    func backfill(_ convId: String) {
        backfilled.remove(convId)
        backfillIfNeeded(convId)
    }
}

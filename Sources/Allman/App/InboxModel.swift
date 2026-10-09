// The inbox: conversation list + per-thread messages, read straight off the
// store and kept fresh by FSEvents. Sends/reactions shell out to the CLI.

import Foundation
import Observation

@MainActor
@Observable
final class InboxModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case unread = "Unread"
        case needsReply = "Needs my reply"
        case awaitingReply = "Awaiting their reply"
        case firstDegree = "1st-degree connections"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .all: return "tray.full"
            case .unread: return "envelope.badge"
            case .needsReply: return "arrowshape.turn.up.left"
            case .awaitingReply: return "paperplane"
            case .firstDegree: return "person.2"
            }
        }
    }

    private(set) var snapshots: [ConversationSnapshot] = []
    private(set) var byId: [String: ConversationSnapshot] = [:]
    private(set) var messages: [String: [Message]] = [:]
    private(set) var isLoading = false
    private(set) var loadingThread: Set<String> = []
    private(set) var backfilling: Set<String> = []
    var readState = ReadState.load() { didSet { recompute() } }
    var selectedConvId: String? { didSet { recompute() } }
    var searchText = "" { didSet { recompute() } }
    var filter: Filter = .all { didSet { recompute() } }
    /// Derived, recomputed only when inputs change — cheap to read from views.
    private(set) var filtered: [ConversationSnapshot] = []
    private(set) var unread: [ConversationSnapshot] = []
    private(set) var unreadCount = 0
    /// Pinned conversations in pin order (only those that still exist).
    private(set) var pinnedSnapshots: [ConversationSnapshot] = []

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

    init(reader: StoreReader) { self.reader = reader }

    // MARK: Derived

    private func recompute() {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        unread = snapshots.filter { readState.isUnread($0) }
        unreadCount = unread.count
        pinnedSnapshots = readState.pins.compactMap { byId[$0] }
        let pinSet = Set(readState.pins)
        let browsing = q.isEmpty && filter == .all
        filtered = snapshots.filter { snap in
            // Pinned threads live in the grid while browsing; searching/filtering shows them in the list.
            if browsing && pinSet.contains(snap.record.convId) && snap.record.convId != selectedConvId { return false }
            if snap.record.convId == selectedConvId { return q.isEmpty || matches(snap, q) }
            switch filter {
            case .all: break
            case .unread: if !readState.isUnread(snap) { return false }
            case .needsReply: if snap.lastMessage?.isFromMe != false { return false }
            case .awaitingReply: if snap.lastMessage?.isFromMe != true { return false }
            case .firstDegree: if snap.record.distance != "DISTANCE_1" { return false }
            }
            return q.isEmpty || matches(snap, q)
        }
    }

    private func matches(_ snap: ConversationSnapshot, _ q: String) -> Bool {
        let r = snap.record
        return r.displayName.lowercased().contains(q)
            || (r.slug?.lowercased().contains(q) ?? false)
            || (r.headline?.lowercased().contains(q) ?? false)
            || (snap.lastMessage?.body.lowercased().contains(q) ?? false)
    }

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
        await reloadAll()
        let w = StoreWatcher(accountDir: account.dir) { [weak self] change in
            guard let self else { return }
            Task { @MainActor in
                if change.structural { await self.reloadAll() } else if !change.convIds.isEmpty { await self.reload(convIds: change.convIds) }
            }
        }
        w.start()
        watcher = w
    }

    func detach() {
        watcher?.stop(); watcher = nil
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
        let msgs = await Task.detached(priority: .userInitiated) { reader.readMessages(accountDir: dir, convId: convId) }.value
        messages[convId] = msgs
        loadingThread.remove(convId)
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
    private var navigationOrder: [ConversationSnapshot] {
        let q = searchText.trimmingCharacters(in: .whitespaces).isEmpty && filter == .all
        return q ? pinnedSnapshots + filtered.filter { !readState.isPinned($0.record.convId) } : filtered
    }

    func selectNext(unreadOnly: Bool = false) { step(1, unreadOnly: unreadOnly) }
    func selectPrevious(unreadOnly: Bool = false) { step(-1, unreadOnly: unreadOnly) }

    private func step(_ delta: Int, unreadOnly: Bool) {
        let rows = navigationOrder
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.record.convId == selectedConvId }
        var i = current.map { $0 + delta } ?? (delta > 0 ? 0 : rows.count - 1)
        while i >= 0, i < rows.count {
            if !unreadOnly || readState.isUnread(rows[i]) { select(rows[i].record.convId); return }
            i += delta
        }
        if unreadOnly, let first = (delta > 0 ? rows : rows.reversed()).first(where: { readState.isUnread($0) }) {
            select(first.record.convId) // wrap around
        }
    }

    // MARK: Selection / read state

    func select(_ convId: String?) {
        if convId != nil, draft != nil { draft = nil }
        selectedConvId = convId
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

    // MARK: Compose

    private(set) var connections: [Connection] = []
    private var connectionsLoaded = false
    /// A recipient with no local thread yet; shown in place of the selected conversation.
    var draft: DraftRecipient? { didSet { recompute() } }

    func loadConnectionsIfNeeded() {
        guard !connectionsLoaded, let dir = accountDir else { return }
        connectionsLoaded = true
        let reader = self.reader
        Task { @MainActor in
            connections = await Task.detached(priority: .utility) { reader.loadConnections(accountDir: dir) }.value
        }
    }

    func startDraft(_ recipient: DraftRecipient) {
        // Reuse an existing thread when the slug already has one.
        if let existing = snapshots.first(where: { $0.record.slug == recipient.slug }) {
            draft = nil
            select(existing.record.convId)
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
        isSending = true
        composerError = nil
        defer { isSending = false }
        do {
            var args = ["send", snap.record.sendTarget, body, "--json"]
            if let reply = replyingTo[target] { args += ["--reply-to", reply.urn] }
            _ = try await AllmanRunner.runJSON(args, as: SendResult.self, context: ctx, timeout: 60)
            replyingTo[target] = nil
            await reload(convIds: [target])
            markSeen(target)
            return true
        } catch let err as AllmanError {
            // The CLI aborts when new inbound messages arrived since the last sync.
            if err.stderr.contains("received before send") {
                composerError = "New messages arrived in this thread — read them, then send again."
                await reload(convIds: [target])
            } else if err.stderr.contains("unknown option") && err.stderr.contains("reply-to") {
                composerError = "Replying to a specific message needs a newer allman CLI."
            } else {
                composerError = err.friendlyMessage
            }
            return false
        } catch {
            composerError = error.localizedDescription
            return false
        }
    }

    /// First message to someone without a local thread. The CLI resolves the
    /// profile, finds or creates the LinkedIn thread, and writes the record.
    private func sendDraft(_ body: String, context ctx: AllmanRunner.Context) async -> Bool {
        guard let recipient = draft else { return false }
        isSending = true
        composerError = nil
        defer { isSending = false }
        do {
            let result = try await AllmanRunner.runJSON(["send", recipient.slug, body, "--json"], as: SendResult.self, context: ctx, timeout: 90)
            let convUrn = result.conversationUrn ?? ""
            let bare = Self.bareConversationId(convUrn)
            await reloadAll()
            draft = nil
            if let bare, byId[bare] != nil {
                select(bare)
            } else if let found = snapshots.first(where: { $0.record.slug == recipient.slug }) {
                select(found.record.convId)
            }
            toast = "Sent to \(recipient.name)"
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

// The inbox: conversation list + per-thread messages, read straight off the
// store and kept fresh by FSEvents. Sends/reactions shell out to the CLI.

import Foundation
import Observation

@MainActor
@Observable
final class InboxModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", unread = "Unread"
        var id: String { rawValue }
    }

    private(set) var snapshots: [ConversationSnapshot] = []
    private(set) var byId: [String: ConversationSnapshot] = [:]
    private(set) var messages: [String: [Message]] = [:]
    private(set) var isLoading = false
    private(set) var loadingThread: Set<String> = []
    private(set) var backfilling: Set<String> = []
    var readState = ReadState.load()
    var selectedConvId: String?
    var searchText = ""
    var filter: Filter = .all
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

    var filtered: [ConversationSnapshot] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return snapshots.filter { snap in
            if filter == .unread && !readState.isUnread(snap) && snap.record.convId != selectedConvId { return false }
            guard !q.isEmpty else { return true }
            let r = snap.record
            return r.displayName.lowercased().contains(q)
                || (r.slug?.lowercased().contains(q) ?? false)
                || (r.headline?.lowercased().contains(q) ?? false)
                || (snap.lastMessage?.body.lowercased().contains(q) ?? false)
        }
    }

    var unreadCount: Int { snapshots.reduce(0) { $0 + (readState.isUnread($1) ? 1 : 0) } }
    var unread: [ConversationSnapshot] { snapshots.filter { readState.isUnread($0) } }
    var selected: ConversationSnapshot? { selectedConvId.flatMap { byId[$0] } }
    func isUnread(_ snap: ConversationSnapshot) -> Bool { readState.isUnread(snap) }

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

    // MARK: Selection / read state

    func select(_ convId: String?) {
        selectedConvId = convId
        composerError = nil
        guard let convId else { return }
        Task { await loadMessages(convId: convId) }
        markSeen(convId)
        backfillIfNeeded(convId)
    }

    func markSeen(_ convId: String) {
        guard let snap = byId[convId] else { return }
        let ts = snap.lastMessage?.timestamp ?? Int64(Date().timeIntervalSince1970 * 1000)
        readState.markSeen(convId, at: max(ts, Int64(Date().timeIntervalSince1970 * 1000)))
        readState.save()
    }

    func markAllSeen() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for snap in snapshots where readState.isUnread(snap) { readState.markSeen(snap.record.convId, at: now) }
        readState.save()
    }

    // MARK: Writes (through the CLI)

    func send(_ text: String, to convId: String? = nil) async -> Bool {
        let target = convId ?? selectedConvId
        guard let target, let snap = byId[target], let ctx = context else { return false }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        isSending = true
        composerError = nil
        defer { isSending = false }
        do {
            _ = try await AllmanRunner.runJSON(["send", snap.record.sendTarget, body, "--json"], as: SendResult.self, context: ctx, timeout: 60)
            await reload(convIds: [target])
            markSeen(target)
            return true
        } catch let err as AllmanError {
            // The CLI aborts when new inbound messages arrived since the last sync.
            if err.stderr.contains("received before send") {
                composerError = "New messages arrived in this thread — read them, then send again."
                await reload(convIds: [target])
            } else {
                composerError = err.errorDescription
            }
            return false
        } catch {
            composerError = error.localizedDescription
            return false
        }
    }

    func react(_ message: Message, in convId: String, emoji: String) async {
        guard let snap = byId[convId], let ctx = context else { return }
        let already = message.reactions.contains { $0.emoji == emoji && $0.hasUserReacted }
        var args = ["react", snap.record.sendTarget, emoji, "--message", message.urn, "--json"]
        if already { args.append("--unreact") }
        do {
            _ = try await AllmanRunner.runJSON(args, as: ReactResult.self, context: ctx, timeout: 30)
            await loadMessages(convId: convId, force: true)
        } catch {
            toast = (error as? AllmanError)?.errorDescription ?? error.localizedDescription
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
                _ = try await AllmanRunner.run(["sync", convId, "--json"], context: ctx, timeout: 600)
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

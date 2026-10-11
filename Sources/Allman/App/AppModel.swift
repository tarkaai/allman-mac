// Root object: discovers the store and every signed-in account, runs a sync
// engine + inbox per account, and wires notifications, windows, and the
// login-item registration together.

import AppKit
import Foundation
import Observation
import ServiceManagement
import os

private let appLog = Logger(subsystem: "sh.allman.mac", category: "app")

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()
    static let currentAccountKey = "currentAccountId"

    let reader: StoreReader
    let notifier = Notifier()
    /// Saved replies, shared by every account.
    let snippets = SnippetStore()

    /// One session per account directory in the store, in slug order.
    private(set) var sessions: [AccountSession] = []
    /// Which account the inbox window and the panel header show.
    private(set) var currentId: String?
    private(set) var binaryURL: URL?
    private(set) var storeURL: URL
    /// `allman login` for a brand-new account is running (browser window open).
    private(set) var isAddingAccount = false

    /// Stand-ins while no account exists, so views never special-case nil.
    private let idleEngine = SyncEngine()
    private let idleInbox: InboxModel
    private let idleNetwork: NetworkModel

    /// Set by the AppKit controllers so model code can open windows.
    var openInboxWindow: (() -> Void)?
    var openSettingsWindow: (() -> Void)?
    /// SwiftUI's openWindow(id:) bridged from a live view; the URL scheme is only a fallback.
    var openNetworkWindow: (() -> Void)?
    var closePanel: (() -> Void)?
    /// Dev snapshots only: show every bubble's timestamp as if hovered.
    var debugShowTimes = false
    /// The contact inspector beside the thread (⌥⌘I). Remembered across launches.
    static let inspectorKey = "inspectorVisible"
    var inspectorVisible: Bool = UserDefaults.standard.bool(forKey: AppModel.inspectorKey) {
        didSet { UserDefaults.standard.set(inspectorVisible, forKey: Self.inspectorKey) }
    }

    private var lastNotifiedAt: [String: Int64] = [:]
    private var loginProc: AllmanProcess?
    private var profileRefreshed: Set<String> = []

    // MARK: Current-account conveniences

    var current: AccountSession? { sessions.first { $0.id == currentId } ?? sessions.first }
    var account: Account? { current?.account }
    var accounts: [Account] { sessions.map(\.account) }
    var inbox: InboxModel { current?.inbox ?? idleInbox }
    var engine: SyncEngine { current?.engine ?? idleEngine }
    var network: NetworkModel { current?.network ?? idleNetwork }
    var accountDisplayName: String { current?.displayName ?? "Allman" }

    /// The menu bar glyph summarizes every account: attention first, then the weakest link.
    var overallStatus: SyncEngine.Status {
        guard !sessions.isEmpty else { return idleEngine.status }
        let statuses = sessions.map(\.engine.status)
        if let s = statuses.first(where: \.needsAttention) { return s }
        if let s = statuses.first(where: { if case .offline = $0 { return true } else { return false } }) { return s }
        if let s = statuses.first(where: { !$0.isHealthy }) { return s }
        return .live
    }
    var isAnySyncing: Bool { sessions.contains { $0.engine.isSyncing } }
    var totalUnread: Int { sessions.reduce(0) { $0 + $1.inbox.unreadCount } }

    init() {
        let store = StorePaths.storeURL
        storeURL = store
        reader = StoreReader(storeURL: store)
        idleInbox = InboxModel(reader: reader, readState: ReadState())
        idleNetwork = NetworkModel(reader: reader)
        currentId = UserDefaults.standard.string(forKey: Self.currentAccountKey)
        notifier.onOpenConversation = { [weak self] accountId, convId in
            self?.openInbox(accountId: accountId, convId: convId.isEmpty ? nil : convId)
        }
        notifier.onReply = { [weak self] accountId, convId, text in
            Task { @MainActor [weak self] in
                guard let self, let session = self.session(accountId) else { return }
                let ok = await session.inbox.send(text, to: convId)
                if !ok { self.notifier.notifyError(title: "Reply not sent", body: session.inbox.composerError ?? "allman send failed") }
            }
        }
        idleEngine.onLoginFinished = { [weak self] ok in if ok { Task { await self?.bootstrap() } } }
    }

    private func session(_ accountId: String?) -> AccountSession? {
        if let accountId, let s = sessions.first(where: { $0.id == accountId }) { return s }
        return current
    }

    // MARK: Bootstrap

    func bootstrap() async {
        ChildRegistry.shared.reapOrphans()
        notifier.setup()
        storeURL = StorePaths.storeURL
        binaryURL = AllmanBinary.resolve()
        refreshAccounts()

        guard !sessions.isEmpty else {
            if binaryURL == nil { idleEngine.markNeedsLogin(reason: nil) }
            idleEngine.markNeedsLogin(reason: "No LinkedIn account in \(storeURL.path)")
            return
        }
        for session in sessions { await start(session) }
    }

    private func start(_ session: AccountSession) async {
        let acct = session.account
        await session.inbox.attach(account: acct, context: session.context)
        session.network.attach(account: acct, context: session.context, inbox: session.inbox)
        session.engine.configure(storeURL: storeURL, account: acct.slug, initialLastSync: acct.auth.lastSyncDate)

        guard acct.auth.isAuthenticated else {
            session.engine.markNeedsLogin(reason: "@\(acct.slug) is signed out")
            return
        }
        // Cookies can be expired even when AUTH.json says authenticated.
        if await cookiesValid(for: session) == false {
            session.engine.markNeedsLogin(reason: "LinkedIn session for @\(acct.slug) expired")
            return
        }
        session.engine.start()
        refreshProfile(session)
    }

    /// Reconcile sessions with the account directories on disk, keeping live ones.
    func refreshAccounts() {
        let found = reader.discoverAccounts()
        var next: [AccountSession] = []
        for acct in found {
            if let existing = sessions.first(where: { $0.id == acct.profileId }) {
                existing.update(account: acct)
                next.append(existing)
            } else {
                next.append(AccountSession(account: acct, reader: reader, storeURL: storeURL))
                appLog.notice("account discovered @\(acct.slug, privacy: .public)")
            }
        }
        for gone in sessions where !next.contains(where: { $0.id == gone.id }) {
            gone.engine.stop()
            gone.inbox.detach()
            gone.network.detach()
        }
        sessions = next
        wire()
        if currentId == nil || !sessions.contains(where: { $0.id == currentId }) {
            // Honour the legacy slug override once, then fall back to the first account.
            let preferred = StorePaths.preferredAccountSlug
            currentId = sessions.first { $0.slug == preferred || $0.id == preferred }?.id ?? sessions.first?.id
            if let currentId { UserDefaults.standard.set(currentId, forKey: Self.currentAccountKey) }
        }
    }

    private func wire() {
        for session in sessions {
            let id = session.id
            session.engine.onListenEvent = { [weak self] ev in self?.handleListen(ev, accountId: id) }
            session.engine.onSyncFinished = { [weak self] _ in self?.refreshAccountAuth(accountId: id) }
            session.engine.onLoginFinished = { [weak self] ok in if ok { Task { await self?.bootstrap() } } }
            session.inbox.onNewInbound = { [weak self] fresh in self?.notifyFromStore(fresh, accountId: id) }
            session.inbox.onReminderDue = { [weak self] snap, snooze in
                let body = snooze.note ?? (snooze.hidden ? "Back in your inbox — you snoozed this thread." : "You asked to come back to this thread.")
                self?.notifier.notifyMessage(accountId: id, convId: snap.record.convId, sender: "Reminder · \(snap.record.displayName)", body: body, urn: "reminder:\(snap.record.convId):\(Int(snooze.until.timeIntervalSince1970))")
            }
        }
    }

    /// Re-read AUTH.json (lastSyncAt moves with every heartbeat/sync; whoami fills the profile).
    func refreshAccountAuth(accountId: String? = nil) {
        for session in sessions where accountId == nil || session.id == accountId {
            guard let auth = reader.readAuth(accountDir: session.account.dir) else { continue }
            let a = session.account
            session.update(account: Account(profileId: a.profileId, slug: a.slug, dir: a.dir, auth: auth))
        }
    }
    func refreshAccountAuth() { refreshAccountAuth(accountId: nil) }

    /// `allman whoami --refresh` once per launch: AUTH.json gets name, headline and
    /// photo (login's browser capture usually leaves them null; the photo URL expires).
    private func refreshProfile(_ session: AccountSession) {
        guard !profileRefreshed.contains(session.id) else { return }
        profileRefreshed.insert(session.id)
        let id = session.id
        Task { @MainActor [weak self] in
            do {
                _ = try await AllmanRunner.run(["whoami", "--refresh", "--json"], context: session.context, timeout: 45)
                self?.refreshAccountAuth(accountId: id)
            } catch let err as AllmanError where err.stderr.contains("unknown command") {
                appLog.notice("allman whoami unavailable (old CLI)")
            } catch {
                appLog.notice("whoami failed for \(session.slug, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func select(accountId: String) {
        guard sessions.contains(where: { $0.id == accountId }), accountId != currentId else { return }
        currentId = accountId
        UserDefaults.standard.set(accountId, forKey: Self.currentAccountKey)
    }

    func restart() {
        for s in sessions { s.engine.stop(); s.inbox.detach() }
        sessions = []
        Task { await bootstrap() }
    }

    func stopAll() {
        for s in sessions { s.engine.stop() }
        idleEngine.stop()
    }

    private struct StatusRow: Decodable {
        let profileId: String?
        let cookiesValid: Bool?
    }

    private func cookiesValid(for session: AccountSession) async -> Bool? {
        guard binaryURL != nil else { return nil }
        do {
            let rows = try await AllmanRunner.runJSON(["status", "--json"], as: [StatusRow].self, context: session.context, timeout: 20)
            return rows.first { $0.profileId == session.id }?.cookiesValid
        } catch {
            return nil // can't tell; let listen/sync surface a real auth failure
        }
    }

    // MARK: Accounts: add / sign out

    /// `allman login` with no account: the browser sign-in creates a new store
    /// directory, and bootstrap picks it up. Existing accounts keep syncing.
    func addAccount(proxy: String? = nil, captureSalesNav: Bool = true) {
        guard loginProc == nil else { return }
        guard let bin = AllmanBinary.resolve() else { idleEngine.markNeedsLogin(reason: nil); return }
        isAddingAccount = true
        var args = ["login"]
        if let proxy, !proxy.trimmingCharacters(in: .whitespaces).isEmpty { args += ["--proxy", proxy.trimmingCharacters(in: .whitespaces)] }
        if !captureSalesNav { args.append("--no-salesnav") }
        let proc = AllmanProcess(binary: bin, arguments: args, storeURL: storeURL, account: nil)
        loginProc = proc
        let before = Set(sessions.map(\.id))
        proc.onExit = { [weak self] code, stderr in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.loginProc = nil
                self.isAddingAccount = false
                if code == 0 {
                    await self.bootstrap()
                    if let added = self.sessions.first(where: { !before.contains($0.id) }) {
                        self.select(accountId: added.id)
                        self.engine.logExternal(ActivityItem(.auth, "Added @\(added.slug)"))
                    }
                } else {
                    let detail = stderr.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) }
                    self.engine.logExternal(ActivityItem(.error, "Adding an account did not complete", detail: detail))
                }
            }
        }
        do { try proc.start() } catch {
            loginProc = nil
            isAddingAccount = false
            engine.logExternal(ActivityItem(.error, "Could not launch sign-in", detail: error.localizedDescription))
        }
    }

    /// `allman logout --account <slug>`: clears the cookies; the directory and
    /// its history stay, and the account shows as signed out until re-authenticated.
    func signOut(_ session: AccountSession) {
        session.engine.stop()
        Task { @MainActor in
            do {
                _ = try await AllmanRunner.run(["logout"], context: session.context, timeout: 30)
            } catch {
                session.engine.logExternal(ActivityItem(.error, "Sign out failed", detail: error.localizedDescription))
            }
            refreshAccountAuth(accountId: session.id)
            session.engine.markNeedsLogin(reason: "@\(session.slug) signed out")
        }
    }

    // MARK: Windows

    func openInbox(convId: String?) { openInbox(accountId: nil, convId: convId) }

    func openInbox(accountId: String?, convId: String?) {
        if let accountId { select(accountId: accountId) }
        if let convId { inbox.select(convId) }
        closePanel?()
        NSApp.activate(ignoringOtherApps: true)
        openInboxWindow?()
    }

    func openSettings() {
        closePanel?()
        openSettingsWindow?()
    }

    func openNetwork() {
        closePanel?()
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "network" && $0.isVisible }) { w.makeKeyAndOrderFront(nil); return }
        if let open = openNetworkWindow { open() } else { NSWorkspace.shared.open(URL(string: "allman://network")!) }
    }

    // MARK: Notifications

    private func handleListen(_ ev: ListenEvent, accountId: String) {
        guard let session = sessions.first(where: { $0.id == accountId }) else { return }
        let inbox = session.inbox
        if ev.event == "read_receipt" {
            // listen already updated RECORD.json when the receipt was ours; FSEvents reloads it.
            return
        }
        if ev.event == "reaction" {
            // The CLI updates the stored message when it can resolve the thread; the
            // open thread is also re-pulled so a reaction removed on linkedin.com disappears here.
            if let sel = inbox.selectedConvId { inbox.refreshRecent(sel, force: true) }
            return
        }
        guard ev.event == "message.received", ev.message?.isFromMe != true else { return }
        guard let convId = ev.conversation?.convId else { return }
        let urn = ev.message?.urn ?? "\(convId):\(Int(ev.timestamp ?? 0))"
        let bare = StoreReader.bareMessageId(urn)
        guard !inbox.readState.hasNotified(bare) else { return }
        // Don't notify about a thread the user is looking at right now.
        if session.id == currentId, inbox.isWindowFocused, inbox.selectedConvId == convId { return }
        inbox.readState.rememberNotified(bare)
        inbox.readState.save()
        lastNotifiedAt[convId] = Int64(ev.timestamp ?? Date().timeIntervalSince1970 * 1000)
        let sender = ev.from?.name ?? ev.conversation?.name ?? "LinkedIn"
        notifier.notifyMessage(accountId: accountId, convId: convId, sender: sender, body: ev.message?.body ?? "", urn: bare)
    }

    /// Messages that landed via sync (missed while offline/asleep) rather than listen.
    private func notifyFromStore(_ fresh: [(ConversationSnapshot, Message)], accountId: String) {
        guard let session = sessions.first(where: { $0.id == accountId }) else { return }
        let inbox = session.inbox
        var pending: [(ConversationSnapshot, Message)] = []
        for (snap, msg) in fresh {
            let bare = StoreReader.bareMessageId(msg.urn)
            if inbox.readState.hasNotified(bare) { continue }
            if let t = lastNotifiedAt[snap.record.convId], abs(t - msg.timestamp) < 3000 { continue }
            if session.id == currentId, inbox.isWindowFocused, inbox.selectedConvId == snap.record.convId { continue }
            pending.append((snap, msg))
        }
        guard !pending.isEmpty else { return }
        for (_, msg) in pending { inbox.readState.rememberNotified(StoreReader.bareMessageId(msg.urn)) }
        inbox.readState.save()
        if pending.count > 3 {
            notifier.notifySummary(count: pending.count, convCount: Set(pending.map { $0.0.record.convId }).count)
        } else {
            for (snap, msg) in pending {
                lastNotifiedAt[snap.record.convId] = msg.timestamp
                notifier.notifyMessage(accountId: accountId, convId: snap.record.convId, sender: snap.record.displayName, body: msg.previewText, urn: StoreReader.bareMessageId(msg.urn))
            }
        }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                engine.logExternal(ActivityItem(.warning, "Couldn't change Launch at Login", detail: error.localizedDescription))
            }
        }
    }
}

extension SyncEngine {
    /// Lets other components drop a line into the activity trail.
    func logExternal(_ item: ActivityItem) {
        // `log` is private(set); route through a tiny internal mutation.
        appendToLog(item)
    }
}

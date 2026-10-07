// Root object: discovers the store + account, wires the inbox, sync engine,
// notifications, and login-item registration together.

import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let reader: StoreReader
    let inbox: InboxModel
    let engine = SyncEngine()
    let notifier = Notifier()

    private(set) var accounts: [Account] = []
    private(set) var account: Account?
    private(set) var binaryURL: URL?
    private(set) var storeURL: URL

    /// Set by the App scene so model code can open the inbox window.
    var openInboxWindow: (() -> Void)?
    var openSettingsWindow: (() -> Void)?
    /// Dev snapshots only: show every bubble's timestamp as if hovered.
    var debugShowTimes = false

    /// AUTH.json often has a null name until the next login; our own sent messages carry it.
    var accountDisplayName: String {
        if let n = account?.auth.name, !n.isEmpty { return n }
        if let mine = inbox.snapshots.lazy.compactMap({ $0.lastMessage }).first(where: { $0.isFromMe && !($0.fromName ?? "").isEmpty }) {
            return mine.fromName!
        }
        return account?.slug ?? "Allman"
    }

    private var lastNotifiedAt: [String: Int64] = [:]

    init() {
        let store = StorePaths.storeURL
        storeURL = store
        reader = StoreReader(storeURL: store)
        inbox = InboxModel(reader: reader)
        wire()
    }

    private func wire() {
        engine.onListenEvent = { [weak self] ev in self?.handleListen(ev) }
        engine.onSyncFinished = { [weak self] _ in self?.refreshAccountAuth() }
        engine.onLoginFinished = { [weak self] ok in if ok { Task { await self?.bootstrap() } } }
        inbox.onNewInbound = { [weak self] fresh in self?.notifyFromStore(fresh) }
        notifier.onOpenConversation = { [weak self] convId in self?.openInbox(convId: convId.isEmpty ? nil : convId) }
        notifier.onReply = { [weak self] convId, text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ok = await self.inbox.send(text, to: convId)
                if !ok { self.notifier.notifyError(title: "Reply not sent", body: self.inbox.composerError ?? "allman send failed") }
            }
        }
    }

    // MARK: Bootstrap

    func bootstrap() async {
        ChildRegistry.shared.reapOrphans()
        notifier.setup()
        storeURL = StorePaths.storeURL
        binaryURL = AllmanBinary.resolve()
        refreshAccounts()

        guard let acct = account else {
            engine.stop()
            inbox.detach()
            if binaryURL == nil { engine.markNeedsLogin(reason: nil) } // panel shows install + sign-in
            engine.markNeedsLogin(reason: "No LinkedIn account in \(storeURL.path)")
            return
        }

        let ctx = AllmanRunner.Context(storeURL: storeURL, account: acct.slug)
        await inbox.attach(account: acct, context: ctx)
        engine.configure(storeURL: storeURL, account: acct.slug, initialLastSync: acct.auth.lastSyncDate)

        guard acct.auth.isAuthenticated else {
            engine.markNeedsLogin(reason: "Account \(acct.slug) is signed out")
            return
        }
        // Cookies can be expired even when AUTH.json says authenticated.
        if await cookiesValid(for: acct, context: ctx) == false {
            engine.markNeedsLogin(reason: "LinkedIn session expired")
            return
        }
        engine.start()
    }

    func refreshAccounts() {
        accounts = reader.discoverAccounts()
        let preferred = StorePaths.preferredAccountSlug
        account = accounts.first { $0.slug == preferred || $0.profileId == preferred } ?? accounts.first
    }

    /// Re-read AUTH.json (lastSyncAt moves with every heartbeat/sync).
    func refreshAccountAuth() {
        guard let acct = account, let auth = reader.readAuth(accountDir: acct.dir) else { return }
        account = Account(profileId: acct.profileId, slug: acct.slug, dir: acct.dir, auth: auth)
    }

    func selectAccount(_ slug: String) {
        UserDefaults.standard.set(slug, forKey: StorePaths.accountOverrideKey)
        engine.stop()
        Task { await bootstrap() }
    }

    func restart() {
        engine.stop()
        inbox.detach()
        Task { await bootstrap() }
    }

    private struct StatusRow: Decodable {
        let profileId: String?
        let cookiesValid: Bool?
    }

    private func cookiesValid(for acct: Account, context: AllmanRunner.Context) async -> Bool? {
        guard binaryURL != nil else { return nil }
        do {
            let rows = try await AllmanRunner.runJSON(["status", "--json"], as: [StatusRow].self, context: context, timeout: 20)
            return rows.first { $0.profileId == acct.profileId }?.cookiesValid
        } catch {
            return nil // can't tell; let listen/sync surface a real auth failure
        }
    }

    // MARK: Windows

    func openInbox(convId: String?) {
        if let convId { inbox.select(convId) }
        NSApp.activate(ignoringOtherApps: true)
        openInboxWindow?()
    }

    // MARK: Notifications

    private func handleListen(_ ev: ListenEvent) {
        guard ev.event == "message.received", ev.message?.isFromMe != true else { return }
        guard let convId = ev.conversation?.convId else { return }
        let urn = ev.message?.urn ?? "\(convId):\(Int(ev.timestamp ?? 0))"
        let bare = StoreReader.bareMessageId(urn)
        guard !inbox.readState.hasNotified(bare) else { return }
        // Don't notify about a thread the user is looking at right now.
        if inbox.isWindowFocused, inbox.selectedConvId == convId { return }
        inbox.readState.rememberNotified(bare)
        inbox.readState.save()
        lastNotifiedAt[convId] = Int64(ev.timestamp ?? Date().timeIntervalSince1970 * 1000)
        let sender = ev.from?.name ?? ev.conversation?.name ?? "LinkedIn"
        notifier.notifyMessage(convId: convId, sender: sender, body: ev.message?.body ?? "", urn: bare)
    }

    /// Messages that landed via sync (missed while offline/asleep) rather than listen.
    private func notifyFromStore(_ fresh: [(ConversationSnapshot, Message)]) {
        var pending: [(ConversationSnapshot, Message)] = []
        for (snap, msg) in fresh {
            let bare = StoreReader.bareMessageId(msg.urn)
            if inbox.readState.hasNotified(bare) { continue }
            if let t = lastNotifiedAt[snap.record.convId], abs(t - msg.timestamp) < 3000 { continue }
            if inbox.isWindowFocused, inbox.selectedConvId == snap.record.convId { continue }
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
                notifier.notifyMessage(convId: snap.record.convId, sender: snap.record.displayName, body: msg.previewText, urn: StoreReader.bareMessageId(msg.urn))
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

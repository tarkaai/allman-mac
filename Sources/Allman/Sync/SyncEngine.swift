// Keeps the local allman store live. Owns the long-running `allman listen`
// subprocess (restarted with backoff), runs `allman sync --json` on launch,
// on a timer, and whenever the network or sleep state changes, and keeps a
// human-readable activity trail for the menu bar panel.
//
// The engine never touches the store itself: it only drives the CLI, which
// owns rate limiting, dedup, and git commits.

import AppKit
import Foundation
import Observation
import os

private let engineLog = Logger(subsystem: "sh.allman.mac", category: "sync")

@MainActor
@Observable
final class SyncEngine {
    enum Status: Equatable {
        case idle
        case noBinary
        case needsLogin
        case loggingIn
        case offline
        case connecting
        case live
        case reconnecting(attempt: Int)
        case error(String)

        var label: String {
            switch self {
            case .idle: return "Starting…"
            case .noBinary: return "allman CLI not found"
            case .needsLogin: return "Sign in required"
            case .loggingIn: return "Waiting for browser sign-in…"
            case .offline: return "Offline"
            case .connecting: return "Connecting…"
            case .live: return "Live"
            case .reconnecting(let n): return "Reconnecting (try \(n))…"
            case .error(let msg): return msg
            }
        }

        /// Menu bar glyph for this state.
        var symbol: String {
            switch self {
            case .live: return "bubble.left.and.bubble.right.fill"
            case .connecting, .reconnecting, .idle: return "bubble.left.and.bubble.right"
            case .offline: return "wifi.slash"
            case .needsLogin, .loggingIn: return "person.crop.circle.badge.exclamationmark"
            case .noBinary, .error: return "exclamationmark.bubble"
            }
        }

        var isHealthy: Bool { if case .live = self { return true } else { return false } }
        var needsAttention: Bool {
            switch self {
            case .needsLogin, .noBinary, .error: return true
            default: return false
            }
        }
    }

    static let syncIntervalKey = "syncIntervalMinutes"

    private(set) var status: Status = .idle
    private(set) var isSyncing = false
    private(set) var syncProgress: String?
    private(set) var lastSyncAt: Date?
    private(set) var lastSyncSummary: String?
    private(set) var lastHeartbeatAt: Date?
    private(set) var log = ActivityLog()
    private(set) var networkInterface = ""

    var syncIntervalMinutes: Int {
        get { max(1, UserDefaults.standard.object(forKey: Self.syncIntervalKey) as? Int ?? 15) }
        set { UserDefaults.standard.set(newValue, forKey: Self.syncIntervalKey); restartPeriodicSync() }
    }

    /// Fired for every NDJSON line from `allman listen` (after status bookkeeping).
    var onListenEvent: ((ListenEvent) -> Void)?
    /// Fired when a sync subprocess exits (success flag).
    var onSyncFinished: ((Bool) -> Void)?
    /// Fired after a login attempt finishes so the owner can re-discover accounts.
    var onLoginFinished: ((Bool) -> Void)?

    private var context: AllmanRunner.Context?
    private var binary: URL?
    private var listenProc: AllmanProcess?
    private var syncProc: AllmanProcess?
    private var loginProc: AllmanProcess?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var staleTask: Task<Void, Never>?
    private var running = false
    private var suppressReconnect = false
    private let network = NetworkMonitor()
    private var observers: [NSObjectProtocol] = []

    // MARK: Lifecycle

    init() {
        network.onChange = { [weak self] online, iface in self?.networkChanged(online: online, interface: iface) }
        network.start()
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemWillSleep() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemDidWake() }
        })
    }

    func configure(storeURL: URL, account: String?, initialLastSync: Date?) {
        context = AllmanRunner.Context(storeURL: storeURL, account: account)
        if lastSyncAt == nil { lastSyncAt = initialLastSync }
    }

    /// Start keeping the store live. Safe to call repeatedly.
    func start() {
        guard let bin = AllmanBinary.resolve() else {
            status = .noBinary
            log.addCoalescing(ActivityItem(.error, "allman CLI not found", detail: "Install it or set the path in Settings"))
            return
        }
        binary = bin
        guard context != nil else { return }
        guard !running else { return }
        running = true
        suppressReconnect = false
        reconnectAttempt = 0
        networkInterface = network.interface
        if !network.isOnline {
            status = .offline
            log.addCoalescing(ActivityItem(.network, "Offline", detail: "Will resume when the network is back"))
            return
        }
        engineLog.notice("engine.start()")
        runSync(from: "1d")
        startListen()
        restartPeriodicSync()
        startStaleCheck()
    }

    func stop() {
        engineLog.notice("engine.stop() status=\(self.status.label, privacy: .public)")
        running = false
        suppressReconnect = true
        reconnectTask?.cancel(); reconnectTask = nil
        periodicTask?.cancel(); periodicTask = nil
        staleTask?.cancel(); staleTask = nil
        listenProc?.terminate(); listenProc = nil
        syncProc?.terminate(); syncProc = nil
        isSyncing = false
        if status != .needsLogin && status != .noBinary { status = .idle }
    }

    /// Switch into the "needs login" state (e.g. AUTH.json says unauthenticated).
    func markNeedsLogin(reason: String? = nil) {
        stop()
        status = .needsLogin
        log.addCoalescing(ActivityItem(.auth, "Sign in required", detail: reason))
    }

    // MARK: Sync

    /// Incremental inbox sync. `from` is a CLI duration ("1d", "7d") or ISO date.
    func syncNow(from: String = "1d", resync: Bool = false) {
        guard context != nil else { return }
        if binary == nil { binary = AllmanBinary.resolve() }
        guard binary != nil else { status = .noBinary; return }
        guard network.isOnline else {
            log.addCoalescing(ActivityItem(.warning, "Can't sync while offline"))
            return
        }
        runSync(from: from, resync: resync)
    }

    private func runSync(from: String, resync: Bool = false) {
        guard let bin = binary, let ctx = context else { return }
        guard syncProc == nil else { return } // one sync at a time; the periodic timer will catch up
        var args = ["sync", "--json", "--from", from]
        if resync { args.append("--resync") }
        let proc = AllmanProcess(binary: bin, arguments: args, storeURL: ctx.storeURL, account: ctx.account)
        syncProc = proc
        isSyncing = true
        syncProgress = "Checking LinkedIn…"
        let startedAt = Date()
        var convs = 0
        var msgs = 0

        proc.onLine = { [weak self] line in
            guard let ev = NDJSON.decode(line, as: SyncEvent.self) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch ev.event {
                case "sync.conversation":
                    convs = ev.conversationsSeen ?? convs + 1
                    self.syncProgress = "\(convs) conversation\(convs == 1 ? "" : "s") checked"
                case "sync.conversation.progress":
                    if let n = ev.messagesFetched, n > 0 {
                        self.syncProgress = "\(convs) conversations · fetching \(ev.name ?? ev.slug ?? "messages")…"
                    }
                case "sync.complete":
                    convs = ev.conversationsSynced ?? convs
                    msgs = ev.messagesSynced ?? 0
                default: break
                }
            }
        }
        proc.onExit = { [weak self] code, stderr in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncProc = nil
                self.isSyncing = false
                self.syncProgress = nil
                let err = AllmanError(command: "sync", exitCode: code, stderr: stderr)
                if code == 0 {
                    self.lastSyncAt = Date()
                    let elapsed = Int(Date().timeIntervalSince(startedAt).rounded())
                    let summary: String
                    if msgs == 0 {
                        summary = "Up to date · \(convs) conversation\(convs == 1 ? "" : "s") checked"
                    } else {
                        summary = "Synced \(msgs) message\(msgs == 1 ? "" : "s") across \(convs) conversation\(convs == 1 ? "" : "s")"
                    }
                    self.lastSyncSummary = summary
                    self.log.addCoalescing(ActivityItem(.sync, summary, detail: "\(elapsed)s · window \(from)"))
                    self.onSyncFinished?(true)
                } else if err.looksLikeAuthFailure {
                    self.markNeedsLogin(reason: "LinkedIn session expired during sync")
                    self.onSyncFinished?(false)
                } else {
                    let detail = err.errorDescription ?? "exit \(code)"
                    self.log.add(ActivityItem(.error, "Sync failed", detail: String(detail.prefix(160))))
                    if case .live = self.status {} else if self.running { self.status = .error("Sync failed") }
                    self.onSyncFinished?(false)
                }
            }
        }
        do { try proc.start() } catch {
            syncProc = nil
            isSyncing = false
            syncProgress = nil
            log.add(ActivityItem(.error, "Could not start sync", detail: error.localizedDescription))
        }
    }

    private func restartPeriodicSync() {
        periodicTask?.cancel()
        guard running else { return }
        let minutes = syncIntervalMinutes
        periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard !Task.isCancelled, let self, self.running, self.network.isOnline else { continue }
                self.runSync(from: "1d")
            }
        }
    }

    // MARK: Listen

    private func startListen() {
        guard running, listenProc == nil, let bin = binary, let ctx = context else { return }
        guard network.isOnline else { status = .offline; return }
        if case .live = status {} else { status = .connecting }

        let proc = AllmanProcess(binary: bin, arguments: ["listen"], storeURL: ctx.storeURL, account: ctx.account)
        listenProc = proc

        proc.onLine = { [weak self] line in
            guard let ev = NDJSON.decode(line, as: ListenEvent.self) else { return }
            Task { @MainActor [weak self] in self?.handleListen(ev) }
        }
        proc.onExit = { [weak self] code, stderr in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.listenProc === proc else { return }
                self.listenProc = nil
                let err = AllmanError(command: "listen", exitCode: code, stderr: stderr)
                if !self.running || self.suppressReconnect { return }
                if err.looksLikeAuthFailure {
                    self.markNeedsLogin(reason: "LinkedIn session expired")
                    return
                }
                let detail = stderr.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
                self.log.addCoalescing(ActivityItem(.warning, "Live connection dropped", detail: detail?.isEmpty == false ? String(detail!.prefix(140)) : nil))
                self.scheduleReconnect()
            }
        }
        do { try proc.start() } catch {
            listenProc = nil
            status = .error("Could not start allman listen")
            log.add(ActivityItem(.error, "Could not start allman listen", detail: error.localizedDescription))
            scheduleReconnect()
        }
    }

    private func handleListen(_ ev: ListenEvent) {
        lastHeartbeatAt = Date()
        switch ev.event {
        case "connected":
            let wasReconnecting: Bool
            if case .reconnecting = status { wasReconnecting = true } else { wasReconnecting = false }
            status = .live
            reconnectAttempt = 0
            log.addCoalescing(ActivityItem(.live, wasReconnecting ? "Live connection restored" : "Live connection established"))
        case "heartbeat":
            if case .live = status {} else { status = .live }
        case "message.received":
            let who = ev.from?.name ?? ev.conversation?.name ?? "Someone"
            let body = (ev.message?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            log.add(ActivityItem(.message, who, detail: body.isEmpty ? "Sent an attachment" : String(body.prefix(140)), convId: ev.conversation?.convId, date: ev.date))
        case "message.sent":
            let who = ev.conversation?.name ?? "a conversation"
            let body = (ev.message?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            log.add(ActivityItem(.sent, "You → \(who)", detail: body.isEmpty ? nil : String(body.prefix(140)), convId: ev.conversation?.convId, date: ev.date))
        default:
            break // typing / read_receipt / reaction: freshness only
        }
        onListenEvent?(ev)
    }

    private func scheduleReconnect() {
        guard running, !suppressReconnect else { return }
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt)), 60)
        status = .reconnecting(attempt: reconnectAttempt)
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.running else { return }
            self.startListen()
        }
    }

    /// LinkedIn heartbeats arrive every ~30s. Silence for several minutes means a
    /// half-open socket; kill the subprocess so the exit handler reconnects.
    private func startStaleCheck() {
        staleTask?.cancel()
        staleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, self.running, let proc = self.listenProc else { continue }
                if case .live = self.status, let beat = self.lastHeartbeatAt, Date().timeIntervalSince(beat) > 240 {
                    self.log.add(ActivityItem(.warning, "No heartbeat for 4 minutes", detail: "Reconnecting"))
                    proc.terminate()
                }
            }
        }
    }

    // MARK: Environment changes

    private func networkChanged(online: Bool, interface: String) {
        engineLog.notice("network changed online=\(online) iface=\(interface, privacy: .public) running=\(self.running)")
        networkInterface = interface
        guard running else { return }
        if online {
            log.add(ActivityItem(.network, "Back online", detail: interface.isEmpty ? nil : "via \(interface)"))
            suppressReconnect = false
            reconnectAttempt = 0
            reconnectTask?.cancel()
            if listenProc == nil { startListen() } else {
                // Interface changed (e.g. Wi-Fi → Ethernet): the old socket is dead even if the process isn't.
                listenProc?.terminate()
            }
            runSync(from: "1d")
        } else {
            log.add(ActivityItem(.network, "Offline", detail: "Live connection paused"))
            suppressReconnect = true
            reconnectTask?.cancel()
            listenProc?.terminate(); listenProc = nil
            status = .offline
        }
    }

    private func systemWillSleep() {
        guard running else { return }
        suppressReconnect = true
        reconnectTask?.cancel()
        listenProc?.terminate(); listenProc = nil
        log.addCoalescing(ActivityItem(.network, "Paused for sleep"))
    }

    private func systemDidWake() {
        guard running else { return }
        log.add(ActivityItem(.network, "Woke from sleep", detail: "Catching up"))
        suppressReconnect = false
        reconnectAttempt = 0
        // Give the network a moment to come back before hammering LinkedIn.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.running else { return }
            if self.network.isOnline {
                self.startListen()
                self.runSync(from: "1d")
            } else {
                self.status = .offline
            }
        }
    }

    // MARK: Login

    /// Runs `allman login`, which opens a Chromium window for the user to sign in.
    func login() {
        guard let ctx = context ?? defaultContext() else { return }
        guard let bin = AllmanBinary.resolve() else { status = .noBinary; return }
        guard loginProc == nil else { return }
        stop()
        status = .loggingIn
        log.add(ActivityItem(.auth, "Opening LinkedIn sign-in", detail: "Complete the login in the browser window"))
        let proc = AllmanProcess(binary: bin, arguments: ["login"] + (ctx.account.map { ["--account", $0] } ?? []), storeURL: ctx.storeURL, account: nil)
        loginProc = proc
        proc.onExit = { [weak self] code, stderr in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.loginProc = nil
                if code == 0 {
                    self.log.add(ActivityItem(.auth, "Signed in to LinkedIn"))
                    self.status = .idle
                    self.onLoginFinished?(true)
                } else {
                    let detail = stderr.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) }
                    self.log.add(ActivityItem(.error, "Sign-in did not complete", detail: detail))
                    self.status = .needsLogin
                    self.onLoginFinished?(false)
                }
            }
        }
        do { try proc.start() } catch {
            loginProc = nil
            status = .needsLogin
            log.add(ActivityItem(.error, "Could not launch sign-in", detail: error.localizedDescription))
        }
    }

    private func defaultContext() -> AllmanRunner.Context? {
        AllmanRunner.Context(storeURL: StorePaths.storeURL, account: StorePaths.preferredAccountSlug)
    }

    var isLoggingIn: Bool { loginProc != nil }

    func appendToLog(_ item: ActivityItem) { log.add(item) }
}

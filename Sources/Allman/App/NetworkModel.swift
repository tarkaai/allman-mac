// Your LinkedIn network through the CLI: pull 1st-degree connections
// (`allman connections`), fill in profiles (`allman enrich`), and send
// connection requests (`allman connect`). The CLI owns pacing, the
// per-hour/per-day volume caps and duplicate checks; this only drives it.

import Foundation
import Observation

struct SentInvitation: Identifiable, Hashable {
    var id: String { inviteeId }
    let inviteeId: String
    let slug: String?
    let note: String?
    let sentAt: Date?
}

extension StoreReader {
    private struct InvitationFile: Decodable {
        let inviteeId: String?
        let publicIdentifier: String?
        let note: String?
        let sentAt: String?
    }

    func loadInvitations(accountDir: URL) -> [SentInvitation] {
        let dir = accountDir.appendingPathComponent("invitations")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { url -> SentInvitation? in
            guard url.pathExtension == "json", (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
                  let data = try? Data(contentsOf: url), let f = try? Self.decoder.decode(InvitationFile.self, from: data) else { return nil }
            return SentInvitation(inviteeId: f.inviteeId ?? url.deletingPathExtension().lastPathComponent, slug: f.publicIdentifier, note: f.note, sentAt: ISO8601.date(f.sentAt))
        }
        .sorted { ($0.sentAt ?? .distantPast) > ($1.sentAt ?? .distantPast) }
    }
}

@MainActor
@Observable
final class NetworkModel {
    enum JobKind: String { case pull = "Pulling connections", enrich = "Fetching profile details", connect = "Sending connection request" }

    struct Job {
        let kind: JobKind
        var progress: String
        var count = 0
    }

    private(set) var job: Job?
    private(set) var lastResult: String?
    private(set) var lastError: String?
    private(set) var invitations: [SentInvitation] = []

    private let reader: StoreReader
    private var context: AllmanRunner.Context?
    private var accountDir: URL?
    private var proc: AllmanProcess?
    /// Reloaded by the inbox when `connections/` changes; we just mirror it.
    weak var inbox: InboxModel?

    init(reader: StoreReader) { self.reader = reader }

    func attach(account: Account, context: AllmanRunner.Context, inbox: InboxModel) {
        self.context = context
        self.accountDir = account.dir
        self.inbox = inbox
        reloadInvitations()
    }

    func detach() {
        cancel()
        context = nil; accountDir = nil; invitations = []
    }

    var isBusy: Bool { job != nil }

    func reloadInvitations() {
        guard let dir = accountDir else { return }
        let reader = self.reader
        Task { @MainActor in
            invitations = await Task.detached(priority: .utility) { reader.loadInvitations(accountDir: dir) }.value
        }
    }

    func cancel() {
        proc?.terminate()
    }

    // MARK: Jobs

    /// `allman connections`: 1st-degree list into the store (idempotent; 100 per page, paced).
    func pullConnections(limit: Int? = nil, salesNav: Bool = false) {
        var args = ["connections"]
        if let limit { args += ["--limit", String(limit)] }
        if salesNav { args.append("--salesnav") }
        run(.pull, args) { [weak self] line, isStderr in
            guard let self, isStderr else { return }
            // "Fetching connections (page size 100, limit ∞)…", "Page 3: 300 so far…"
            if line.hasPrefix("Fetching") || line.lowercased().contains("page") { self.job?.progress = line.trimmingCharacters(in: .whitespaces) }
        } done: { [weak self] code, stderr in
            self?.finish(code, stderr, success: { "Connections updated" })
        }
    }

    /// `allman enrich --json [--limit N] [--deep]`: profiles for stored connections that lack them.
    func enrichMissing(limit: Int, deep: Bool) {
        var args = ["enrich", "--json", "--limit", String(limit)]
        if deep { args.append("--deep") }
        run(.enrich, args) { [weak self] line, isStderr in
            guard let self else { return }
            if !isStderr, line.hasPrefix("{") {
                self.job?.count += 1
                self.job?.progress = "\(self.job?.count ?? 0) of up to \(limit) profiles"
            } else if isStderr, line.lowercased().contains("quota") {
                self.job?.progress = line.trimmingCharacters(in: .whitespaces)
            }
        } done: { [weak self] code, stderr in
            guard let self else { return }
            let n = self.job?.count ?? 0
            self.finish(code, stderr, success: { "Enriched \(n) profile\(n == 1 ? "" : "s")" + (stderr.lowercased().contains("quota") ? " · quota reached, more later" : "") })
        }
    }

    /// `allman connect <slug> [--note …]` — a real, irreversible invitation. The CLI refuses
    /// people already connected or already invited, and enforces the daily cap.
    func connect(slug: String, note: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        var args = ["connect", slug, "--json"]
        if let note, !note.trimmingCharacters(in: .whitespaces).isEmpty { args += ["--note", note] }
        run(.connect, args) { _, _ in } done: { [weak self] code, stderr in
            guard let self else { return }
            self.finish(code, stderr, success: { "Connection request sent to @\(slug)" })
            if code == 0 { completion(.success(())) } else { completion(.failure(AllmanError(command: "connect", exitCode: code, stderr: stderr))) }
            self.reloadInvitations()
        }
    }

    private func run(_ kind: JobKind, _ args: [String], onLine: @escaping (String, Bool) -> Void, done: @escaping (Int32, String) -> Void) {
        guard job == nil, let ctx = context, let bin = AllmanBinary.resolve() else { return }
        let p = AllmanProcess(binary: bin, arguments: args, storeURL: ctx.storeURL, account: ctx.account)
        job = Job(kind: kind, progress: "Starting…")
        lastError = nil; lastResult = nil
        p.onLine = { line in Task { @MainActor in onLine(line, false) } }
        p.onStderr = { text in
            for line in text.split(separator: "\n") where !line.isEmpty { Task { @MainActor in onLine(String(line), true) } }
        }
        p.onExit = { [weak self] code, stderr in
            Task { @MainActor in
                self?.proc = nil
                done(code, stderr)
            }
        }
        do { try p.start(); proc = p } catch {
            job = nil
            lastError = error.localizedDescription
        }
    }

    private func finish(_ code: Int32, _ stderr: String, success: () -> String) {
        job = nil
        if code == 0 {
            lastResult = success()
        } else {
            let err = AllmanError(command: "", exitCode: code, stderr: stderr)
            lastError = code == 15 || stderr.contains("SIGTERM") ? "Stopped" : err.friendlyMessage
        }
        inbox?.loadConnectionsIfNeeded()
        Task { await inbox?.reloadConnections() }
    }

    /// Has an invitation already been recorded for this person?
    func invited(slug: String) -> SentInvitation? { invitations.first { $0.slug == slug } }
}

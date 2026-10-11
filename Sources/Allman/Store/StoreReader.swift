// Direct, read-only access to the allman file store. Fast enough to re-read a
// few thousand RECORD.json files in a few hundred ms on a background queue.
// Writes always go through the CLI (see AllmanProcess) — the app never
// mutates the store itself.

import Foundation

struct StoreReader: Sendable {
    let storeURL: URL

    init(storeURL: URL = StorePaths.storeURL) {
        self.storeURL = storeURL
    }

    private static let decoder = JSONDecoder()
    private static let convIdPrefix = "2-"
    private static let profileIdPrefix = "ACo"

    // MARK: Accounts

    func discoverAccounts() -> [Account] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: storeURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // {slug} -> {profileId} symlinks at the store root give us friendly names.
        var slugByProfileId: [String: String] = [:]
        for url in entries {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
                  let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else { continue }
            let profileId = (target as NSString).lastPathComponent
            if slugByProfileId[profileId] == nil { slugByProfileId[profileId] = url.lastPathComponent }
        }

        var accounts: [Account] = []
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix(Self.profileIdPrefix),
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let authURL = url.appendingPathComponent("AUTH.json")
            guard let data = try? Data(contentsOf: authURL),
                  let auth = try? Self.decoder.decode(AccountAuth.self, from: data) else { continue }
            accounts.append(Account(
                profileId: name,
                slug: slugByProfileId[name] ?? auth.profileSlug ?? name,
                dir: url,
                auth: auth
            ))
        }
        return accounts.sorted { $0.slug < $1.slug }
    }

    func readAuth(accountDir: URL) -> AccountAuth? {
        guard let data = try? Data(contentsOf: accountDir.appendingPathComponent("AUTH.json")) else { return nil }
        return try? Self.decoder.decode(AccountAuth.self, from: data)
    }

    // MARK: Conversations

    func conversationIds(accountDir: URL) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: accountDir,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(Self.convIdPrefix) else { return nil }
            let rv = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard rv?.isSymbolicLink != true, rv?.isDirectory == true else { return nil }
            return name
        }
    }

    func readRecord(accountDir: URL, convId: String) -> ConversationRecord? {
        let url = accountDir.appendingPathComponent(convId).appendingPathComponent("RECORD.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(ConversationRecord.self, from: data)
    }

    /// Loads every conversation plus its last message, in parallel.
    func loadAll(accountDir: URL) -> [ConversationSnapshot] {
        let ids = conversationIds(accountDir: accountDir)
        var results = [ConversationSnapshot?](repeating: nil, count: ids.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: ids.count) { i in
            let snap = loadSnapshot(accountDir: accountDir, convId: ids[i])
            lock.lock(); results[i] = snap; lock.unlock()
        }
        return results.compactMap { $0 }
    }

    func loadSnapshot(accountDir: URL, convId: String) -> ConversationSnapshot? {
        guard let record = readRecord(accountDir: accountDir, convId: convId) else { return nil }
        let tail = readTail(accountDir: accountDir, convId: convId)
        return ConversationSnapshot(record: record, lastMessage: tail.last, inboundTimestamps: tail.inbound)
    }

    /// Newest message plus the inbound timestamps from the newest month file —
    /// enough to count "messages since you last read" without loading history.
    func readTail(accountDir: URL, convId: String) -> (last: Message?, inbound: [Int64]) {
        let files = messageFiles(accountDir: accountDir, convId: convId)
        for file in files.reversed() {
            let msgs = Self.dedupe(Self.parseJSONL(file).sorted { $0.timestamp < $1.timestamp })
            guard let newest = msgs.last else { continue }
            let inbound = msgs.filter { !$0.isFromMe }.suffix(100).map(\.timestamp)
            return (newest, Array(inbound))
        }
        return (nil, [])
    }

    // MARK: Media

    /// Files `allman media` downloaded for a thread, keyed "<bareMessageId>-<attachmentIndex>".
    func mediaFiles(accountDir: URL, convId: String) -> [String: URL] {
        let dir = accountDir.appendingPathComponent(convId).appendingPathComponent("media")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [:] }
        var out: [String: URL] = [:]
        for f in files { out[f.deletingPathExtension().lastPathComponent] = f }
        return out
    }

    static func mediaKey(messageUrn: String, index: Int) -> String { "\(bareMessageId(messageUrn))-\(index)" }

    // MARK: Messages

    private func messageFiles(accountDir: URL, convId: String) -> [URL] {
        let dir = accountDir.appendingPathComponent(convId).appendingPathComponent("messages")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func readMessages(accountDir: URL, convId: String) -> [Message] {
        var out: [Message] = []
        for file in messageFiles(accountDir: accountDir, convId: convId) {
            out.append(contentsOf: Self.parseJSONL(file))
        }
        out.sort { $0.timestamp < $1.timestamp }
        return Self.dedupe(out)
    }

    /// Reads only the newest month file and returns its last well-formed line.
    func readLastMessage(accountDir: URL, convId: String) -> Message? {
        let files = messageFiles(accountDir: accountDir, convId: convId)
        for file in files.reversed() {
            let msgs = Self.parseJSONL(file)
            if let newest = msgs.max(by: { $0.timestamp < $1.timestamp }) { return newest }
        }
        return nil
    }

    static func parseJSONL(_ url: URL) -> [Message] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parseJSONL(data: data)
    }

    static func parseJSONL(data: Data) -> [Message] {
        var out: [Message] = []
        data.split(separator: UInt8(ascii: "\n")).forEach { line in
            guard !line.isEmpty, let m = try? decoder.decode(Message.self, from: Data(line)) else { return }
            out.append(m)
        }
        return out
    }

    /// The CLI dedupes by bare message id on write, but an interrupted append can
    /// leave the same message twice. Keep the last occurrence.
    static func dedupe(_ messages: [Message]) -> [Message] {
        var seen: [String: Int] = [:]
        var out: [Message] = []
        for m in messages {
            let key = bareMessageId(m.urn)
            if let idx = seen[key] { out[idx] = m } else { seen[key] = out.count; out.append(m) }
        }
        return out
    }

    static func bareMessageId(_ urn: String) -> String {
        if let comma = urn.lastIndex(of: ",") {
            return String(urn[urn.index(after: comma)...]).replacingOccurrences(of: ")", with: "")
        }
        if let colon = urn.lastIndex(of: ":") { return String(urn[urn.index(after: colon)...]) }
        return urn
    }
}

/// A conversation as the UI sees it: the record plus the newest message.
struct ConversationSnapshot: Identifiable, Hashable {
    var id: String { record.convId }
    let record: ConversationRecord
    let lastMessage: Message?
    /// Timestamps of recent inbound messages (newest month), ascending.
    let inboundTimestamps: [Int64]

    init(record: ConversationRecord, lastMessage: Message?, inboundTimestamps: [Int64] = []) {
        self.record = record
        self.lastMessage = lastMessage
        self.inboundTimestamps = inboundTimestamps
    }

    /// Sort key: newest message wins, else LinkedIn's lastActivityAt.
    var activityDate: Date {
        if let m = lastMessage { return m.date }
        return record.lastActivityDate ?? .distantPast
    }
}

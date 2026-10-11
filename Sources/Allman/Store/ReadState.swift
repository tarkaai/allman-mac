// App-owned "I've seen this" watermarks. LinkedIn has no CLI-exposed mark-read,
// so the app tracks what the user opened here. Stored under Application Support,
// not in the store, so the CLI's git history stays clean.

import Foundation

struct ReadState: Codable {
    /// convId -> unix ms of the newest message the user has seen in the app.
    var seenAt: [String: Int64] = [:]
    /// First launch — anything older is considered already-read unless LinkedIn says otherwise.
    var baseline: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    /// Message URNs already surfaced as notifications (bounded).
    var notified: [String] = []
    /// Pinned conversation ids, in display order (Messages-style favorites).
    var pinned: [String]? = []

    /// Where this state persists. Not encoded; set by `load(accountId:)`.
    var fileURL: URL?

    private enum CodingKeys: String, CodingKey { case seenAt, baseline, notified, pinned }

    /// Pre-multi-account file; migrated into the first account's file on first load.
    static let legacyFileURL = StorePaths.appSupportURL.appendingPathComponent("read-state.json")

    static func fileURL(accountId: String?) -> URL {
        guard let accountId, !accountId.isEmpty else { return legacyFileURL }
        let safe = accountId.replacingOccurrences(of: "/", with: "_")
        return StorePaths.appSupportURL.appendingPathComponent("read-state-\(safe).json")
    }

    /// Per-account state so two signed-in accounts never clobber each other's
    /// watermarks and pins. The legacy single file seeds the first account.
    static func load(accountId: String? = nil) -> ReadState {
        let url = fileURL(accountId: accountId)
        var state = read(url) ?? (accountId != nil ? read(legacyFileURL) : nil) ?? ReadState()
        state.fileURL = url
        return state
    }

    private static func read(_ url: URL) -> ReadState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ReadState.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: fileURL ?? Self.legacyFileURL, options: .atomic)
    }

    mutating func markSeen(_ convId: String, at ms: Int64) {
        seenAt[convId] = max(seenAt[convId] ?? 0, ms)
    }

    mutating func rememberNotified(_ urn: String) {
        notified.append(urn)
        if notified.count > 500 { notified.removeFirst(notified.count - 500) }
    }

    func hasNotified(_ urn: String) -> Bool { notified.contains(urn) }

    static let maxPins = 9
    var pins: [String] { pinned ?? [] }
    func isPinned(_ convId: String) -> Bool { pins.contains(convId) }

    mutating func togglePin(_ convId: String) {
        var p = pins
        if let i = p.firstIndex(of: convId) { p.remove(at: i) } else {
            guard p.count < Self.maxPins else { return }
            p.append(convId)
        }
        pinned = p
    }

    mutating func movePin(_ convId: String, to index: Int) {
        var p = pins
        guard let i = p.firstIndex(of: convId) else { return }
        p.remove(at: i)
        p.insert(convId, at: min(max(index, 0), p.count))
        pinned = p
    }

    /// Unread = newest message is inbound, the user hasn't opened it since, and
    /// either LinkedIn flags it unread or it arrived after we first launched.
    func isUnread(_ snap: ConversationSnapshot) -> Bool { unreadCount(snap) > 0 }

    /// Messages since the user last read the thread (here or on linkedin.com).
    func unreadCount(_ snap: ConversationSnapshot) -> Int {
        guard let last = snap.lastMessage, !last.isFromMe else { return 0 }
        let seen = seenAt[snap.record.convId] ?? 0
        if last.timestamp <= seen { return 0 }
        let linkedInRead = snap.record.lastReadDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        // LinkedIn's own read state wins whenever it is at least as new as the message:
        // either a read marker after the message, or a record refreshed after it that says read.
        let fetchedMs = ISO8601.date(snap.record.fetchedAt).map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        let linkedInSaysRead = (snap.record.unreadCount ?? 0) == 0 && snap.record.read != false
        if linkedInSaysRead && (linkedInRead >= last.timestamp || fetchedMs >= last.timestamp) { return 0 }
        let linkedInUnread = (snap.record.unreadCount ?? 0) > 0 || snap.record.read == false
        guard linkedInUnread || last.timestamp > baseline else { return 0 }
        let watermark = max(seen, linkedInRead)
        let counted = snap.inboundTimestamps.filter { $0 > watermark }.count
        if counted > 0 { return counted }
        return max(1, snap.record.unreadCount ?? 1)
    }
}

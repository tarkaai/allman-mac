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

    static let fileURL = StorePaths.appSupportURL.appendingPathComponent("read-state.json")

    static func load() -> ReadState {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(ReadState.self, from: data) else { return ReadState() }
        return s
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
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
        let linkedInUnread = (snap.record.unreadCount ?? 0) > 0 || snap.record.read == false
        guard linkedInUnread || last.timestamp > baseline else { return 0 }
        let linkedInRead = snap.record.lastReadDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        let watermark = max(seen, linkedInRead)
        let counted = snap.inboundTimestamps.filter { $0 > watermark }.count
        if counted > 0 { return counted }
        return max(1, snap.record.unreadCount ?? 1)
    }
}

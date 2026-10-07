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

    /// Unread = newest message is inbound, the user hasn't opened it since, and
    /// either LinkedIn flags it unread or it arrived after we first launched.
    func isUnread(_ snap: ConversationSnapshot) -> Bool {
        guard let last = snap.lastMessage, !last.isFromMe else { return false }
        if last.timestamp <= (seenAt[snap.record.convId] ?? 0) { return false }
        let linkedInUnread = (snap.record.unreadCount ?? 0) > 0 || snap.record.read == false
        return linkedInUnread || last.timestamp > baseline
    }
}

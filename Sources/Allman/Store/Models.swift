// Mirrors the allman store's on-disk shapes (RECORD.json, YYYY-MM.jsonl, AUTH.json).
// Everything optional is optional because older records omit fields; the app
// must never fail to load a conversation over a missing key.

import Foundation

struct ProfilePicture: Codable, Hashable {
    let width: Int
    let height: Int
    let url: String
}

struct SyncState: Codable, Hashable {
    var oldestMessageAt: Int64?
    var newestMessageAt: Int64?
    var lastSyncAt: String?
    var totalSynced: Int?
    var fullyBackfilled: Bool?
}

/// One participant of a group thread (everyone except the signed-in user).
struct Participant: Codable, Hashable, Identifiable {
    var id: String { profileId ?? profileUrn ?? name ?? "" }
    let profileId: String?
    let profileUrn: String?
    /// `urn:li:msg_messagingParticipant:…` — what some message `fromUrn`s carry.
    let backendUrn: String?
    let slug: String?
    let firstName: String?
    let lastName: String?
    let name: String?
    let headline: String?
    let profileUrl: String?
    let profilePictures: [ProfilePicture]?
    let distance: String?
    let pronoun: String?
    let isPremium: Bool?
    let isVerified: Bool?

    var displayName: String {
        let n = (name ?? "").trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        let joined = [firstName, lastName].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? (slug ?? profileId ?? "Someone") : joined
    }

    var avatarURL: URL? { ConversationRecord.pick(profilePictures) }

    /// True when a message's `fromUrn` is this person, whichever URN form the CLI stored.
    func matches(fromUrn: String?) -> Bool {
        guard let fromUrn, !fromUrn.isEmpty else { return false }
        if let u = profileUrn, u == fromUrn { return true }
        if let b = backendUrn, b == fromUrn { return true }
        if let id = profileId, !id.isEmpty, fromUrn.hasSuffix(id) { return true }
        return false
    }
}

/// One conversation: a contact (1:1) or, when `isGroup`, several participants.
struct ConversationRecord: Codable, Identifiable, Hashable {
    var id: String { convId }

    let convId: String
    let profileId: String?
    let slug: String?
    let convUrn: String?
    let backendUrn: String?
    let profileUrn: String?
    let firstName: String?
    let lastName: String?
    let name: String?
    let headline: String?
    let profileUrl: String?
    let profilePictures: [ProfilePicture]?
    let distance: String?
    let pronoun: String?
    let isPremium: Bool?
    let isVerified: Bool?
    let unreadCount: Int?
    let lastActivityAt: String?
    let lastReadAt: String?
    let read: Bool?
    let notificationStatus: String?
    let categories: [String]?
    let conversationUrl: String?
    let syncState: SyncState?
    /// ISO timestamp of the last time the CLI refreshed this record from LinkedIn.
    let fetchedAt: String?
    // Group threads (allman-cli ≥ 0.6): absent on 1:1 records.
    let isGroup: Bool?
    /// LinkedIn's group title, when the members named the thread.
    let title: String?
    /// Everyone in the thread except the signed-in user, in LinkedIn's order.
    let participants: [Participant]?

    var isGroupThread: Bool { isGroup == true || (participants?.count ?? 0) > 1 }
    var members: [Participant] { participants ?? [] }

    var displayName: String {
        if isGroupThread {
            let t = (title ?? "").trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
            let names = members.map(\.displayName).filter { !$0.isEmpty }
            if !names.isEmpty { return names.joined(separator: ", ") }
        }
        let n = (name ?? "").trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        let joined = [firstName, lastName].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? (slug ?? convId) : joined
    }

    /// Short form for tight spots (pins): the group's first names, else the person's first name.
    var shortName: String {
        if isGroupThread, (title ?? "").isEmpty {
            let firsts = members.compactMap { $0.firstName?.isEmpty == false ? $0.firstName : $0.displayName.split(separator: " ").first.map(String.init) }
            if !firsts.isEmpty { return firsts.joined(separator: ", ") }
        }
        return firstName?.isEmpty == false ? firstName! : displayName
    }

    /// Who sent a message, for group threads (nil for 1:1 or when unknown).
    func participant(for message: Message) -> Participant? {
        guard isGroupThread, !message.isFromMe else { return nil }
        if let p = members.first(where: { $0.matches(fromUrn: message.fromUrn) }) { return p }
        if let n = message.fromName, let p = members.first(where: { $0.displayName == n }) { return p }
        return nil
    }

    /// Best `allman send` / `allman react` target: slug when known, else the conversation id
    /// (a group has no slug alias; the CLI resolves the bare `2-…` id).
    var sendTarget: String { isGroupThread ? convId : (slug ?? convUrn ?? backendUrn ?? convId) }

    var avatarURL: URL? { isGroupThread ? nil : Self.pick(profilePictures) }

    /// Prefer ~200px for list rows; the largest is overkill for a 36pt avatar.
    static func pick(_ pics: [ProfilePicture]?) -> URL? {
        guard let pics, !pics.isEmpty else { return nil }
        let sorted = pics.sorted { abs($0.width - 200) < abs($1.width - 200) }
        return sorted.first.flatMap { URL(string: $0.url) }
    }

    var linkedInProfileURL: URL? {
        if isGroupThread { return nil }
        if let slug { return URL(string: "https://www.linkedin.com/in/\(slug)/") }
        if let profileUrl { return URL(string: profileUrl) }
        return nil
    }

    var linkedInThreadURL: URL? {
        if let conversationUrl { return URL(string: conversationUrl) }
        return URL(string: "https://www.linkedin.com/messaging/thread/\(convId)/")
    }

    var lastActivityDate: Date? { ISO8601.date(lastActivityAt) }
    var lastReadDate: Date? { ISO8601.date(lastReadAt) }
}

struct Reaction: Codable, Hashable {
    let emoji: String
    let count: Int
    let hasUserReacted: Bool
}

struct Attachment: Codable, Hashable {
    let type: String?
    let url: String?
    let name: String?
    let size: Int?
    let mimeType: String?
    let previewUrl: String?
    let width: Int?
    let height: Int?
    let durationMs: Int?
    let title: String?
    let description: String?
    let originalText: String?
    let authorName: String?
    // `raw` is intentionally not modelled — Codable ignores unknown keys.

    /// Short placeholder matching the CLI's INBOX.jsonl summaries.
    var summary: String {
        switch type {
        case "post_share": return authorName.map { "Shared a post by \($0)" } ?? "Shared a post"
        case "link_preview": return title.map { "Link: \($0)" } ?? "Shared a link"
        case "image": return "Image"
        case "gif": return "GIF"
        case "video": return durationText.map { "Video · \($0)" } ?? "Video"
        case "audio", "voice": return durationText.map { "Voice message · \($0)" } ?? "Voice message"
        case "file": return name.map { "File: \($0)" } ?? "File"
        case "forwarded": return authorName.map { "Forwarded from \($0)" } ?? "Forwarded message"
        case "replied": return originalText.map { "Replying to “\($0.prefix(60))”" } ?? "Reply"
        case "unavailable": return "Unavailable message"
        case "away_message": return "Away message"
        default: return "Attachment"
        }
    }

    var symbolName: String {
        switch type {
        case "post_share": return "doc.richtext"
        case "link_preview": return "link"
        case "image", "gif": return "photo"
        case "video": return "video"
        case "audio", "voice": return "waveform"
        case "file": return "doc"
        case "forwarded": return "arrowshape.turn.up.right"
        case "replied": return "arrowshape.turn.up.left"
        default: return "paperclip"
        }
    }

    private var durationText: String? {
        guard let ms = durationMs, ms > 0 else { return nil }
        let total = Int((Double(ms) / 1000).rounded())
        let m = total / 60, s = total % 60
        return m == 0 ? "\(s)s" : "\(m)m \(s)s"
    }

    var linkURL: URL? { (url ?? previewUrl).flatMap { URL(string: $0) } }
}

struct Message: Codable, Identifiable, Hashable {
    var id: String { urn }

    let urn: String
    /// Unix milliseconds.
    let timestamp: Int64
    let fromUrn: String?
    let fromName: String?
    let isFromMe: Bool
    let body: String
    var reactions: [Reaction]
    let attachments: [Attachment]
    let originToken: String?
    let subject: String?

    var date: Date { Date(timeIntervalSince1970: Double(timestamp) / 1000) }

    /// Body, or a placeholder for attachment-only messages.
    var previewText: String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let a = attachments.first { return a.summary }
        return ""
    }
}

/// AUTH.json — written by the CLI. `name` is often null until the next login.
struct AccountAuth: Codable, Hashable {
    let urn: String?
    let profileSlug: String?
    let name: String?
    let headline: String?
    let profileUrl: String?
    let imageUrl: String?
    let userType: String?
    let status: String?
    let lastSyncAt: String?

    var isAuthenticated: Bool { status == "authenticated" }
    var lastSyncDate: Date? { ISO8601.date(lastSyncAt) }
}

struct Account: Identifiable, Hashable {
    var id: String { profileId }
    let profileId: String
    /// Friendly slug from the top-level symlink (e.g. "toobulkeh"), falling back to AUTH.profileSlug / id.
    let slug: String
    let dir: URL
    let auth: AccountAuth

    var displayName: String {
        if let n = auth.name, !n.isEmpty { return n }
        return slug
    }
}

enum ISO8601 {
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return withFractional.date(from: s) ?? plain.date(from: s)
    }
}

extension Attachment {
    /// The "replied" quote an outgoing reply will carry once the CLI stores it.
    /// (In an extension so the struct keeps its memberwise init.)
    init(replyingTo original: Message) {
        self.init(type: "replied", url: nil, name: nil, size: nil, mimeType: nil, previewUrl: nil, width: nil, height: nil, durationMs: nil, title: nil, description: nil, originalText: original.previewText, authorName: original.isFromMe ? "You" : original.fromName)
    }
}

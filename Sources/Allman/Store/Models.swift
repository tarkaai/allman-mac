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

/// One conversation = one contact (allman only stores 1:1 threads).
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

    var displayName: String {
        let n = (name ?? "").trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        let joined = [firstName, lastName].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? (slug ?? convId) : joined
    }

    /// Best `allman send` / `allman react` target: slug when known, else the conversation URN.
    var sendTarget: String { slug ?? convUrn ?? backendUrn ?? convId }

    var avatarURL: URL? {
        guard let pics = profilePictures, !pics.isEmpty else { return nil }
        // Prefer ~200px for list rows; the largest is overkill for a 36pt avatar.
        let sorted = pics.sorted { abs($0.width - 200) < abs($1.width - 200) }
        return sorted.first.flatMap { URL(string: $0.url) }
    }

    var linkedInProfileURL: URL? {
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

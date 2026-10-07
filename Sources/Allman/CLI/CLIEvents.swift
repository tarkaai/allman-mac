// NDJSON events the CLI emits on stdout: `allman listen` and `allman sync --json`.
// Field names mirror cli/src/commands/listen.ts and sync.ts exactly.

import Foundation

struct ListenEvent: Decodable {
    struct Conversation: Decodable {
        let urn: String?
        let convId: String?
        let name: String?
        let slug: String?
    }
    struct From: Decodable {
        let urn: String?
        let name: String?
    }
    struct Msg: Decodable {
        let urn: String?
        let body: String?
        let isFromMe: Bool?
    }

    let event: String // connected | heartbeat | message.received | message.sent | typing | read_receipt | reaction
    let account: String?
    let timestamp: Double? // unix ms
    let connectionId: String?
    let conversation: Conversation?
    let from: From?
    let message: Msg?
    let messageUrn: String?

    var date: Date { Date(timeIntervalSince1970: (timestamp ?? Date().timeIntervalSince1970 * 1000) / 1000) }
}

struct SyncEvent: Decodable {
    let event: String // sync.start | sync.conversation | sync.conversation.progress | sync.complete
    let scope: String?
    let account: String?
    let convId: String?
    let slug: String?
    let name: String?
    let conversationsSeen: Int?
    let messagesFetched: Int?
    let conversationsSynced: Int?
    let messagesSynced: Int?
    let from: Double?
    let to: Double?
}

struct SendResult: Decodable {
    let messageUrn: String?
    let conversationUrn: String?
    let deliveredAt: Double?
    let isNewConversation: Bool?
}

struct ReactResult: Decodable {
    let messageUrn: String?
    let emoji: String?
    let action: String?
}

enum NDJSON {
    static let decoder = JSONDecoder()
    static func decode<T: Decodable>(_ line: String, as: T.Type) -> T? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }
}

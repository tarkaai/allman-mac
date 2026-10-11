import XCTest
@testable import Allman

final class MessageSearchTests: XCTestCase {
    private func makeStore() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("allman-search-\(UUID().uuidString)")
        let account = root.appendingPathComponent("ACoTEST")
        for (conv, lines) in [
            ("2-A", [
                #"{"urn":"urn:li:messagingMessage:1","timestamp":1000,"isFromMe":false,"body":"Let's grab coffee next week","reactions":[],"attachments":[]}"#,
                #"{"urn":"urn:li:messagingMessage:2","timestamp":2000,"isFromMe":true,"body":"Sure — Tuesday works","reactions":[],"attachments":[]}"#,
            ]),
            ("2-B", [
                #"{"urn":"urn:li:messagingMessage:3","timestamp":3000,"isFromMe":false,"body":"Café downtown has great COFFEE","reactions":[],"attachments":[]}"#,
                #"{"urn":"urn:li:messagingMessage:3","timestamp":3000,"isFromMe":false,"body":"Café downtown has great COFFEE","reactions":[],"attachments":[]}"#,
            ]),
        ] {
            let dir = account.appendingPathComponent(conv).appendingPathComponent("messages")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{"convId":"\#(conv)","name":"Person \#(conv)"}"#.write(to: account.appendingPathComponent(conv).appendingPathComponent("RECORD.json"), atomically: true, encoding: .utf8)
            try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("2026-01.jsonl"), atomically: true, encoding: .utf8)
        }
        return (root, account)
    }

    func testFindsAcrossConversationsCaseInsensitiveNewestFirstDeduped() throws {
        let (root, account) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let hits = StoreReader(storeURL: root).searchMessages(accountDir: account, query: "coffee")
        XCTAssertEqual(hits.map(\.convId), ["2-B", "2-A"])
        XCTAssertEqual(hits.count, 2, "duplicate JSONL lines collapse to one hit")
        XCTAssertTrue(StoreReader(storeURL: root).searchMessages(accountDir: account, query: "tuesday").first?.message.isFromMe == true)
        XCTAssertTrue(StoreReader(storeURL: root).searchMessages(accountDir: account, query: "zzz").isEmpty)
    }

    func testSnippetWindowsAroundMatch() {
        let m = Message(urn: "u", timestamp: 0, fromUrn: nil, fromName: nil, isFromMe: false, body: String(repeating: "a", count: 100) + "\nNEEDLE here" + String(repeating: "b", count: 200), reactions: [], attachments: [], originToken: nil, subject: nil)
        let s = MessageHit(convId: "2-A", message: m).snippet(for: "needle", before: 10, after: 12)
        XCTAssertTrue(s.hasPrefix("…"), s)
        XCTAssertTrue(s.hasSuffix("…"), s)
        XCTAssertTrue(s.contains("NEEDLE here"), s)
        XCTAssertFalse(s.contains("\n"))
    }
}

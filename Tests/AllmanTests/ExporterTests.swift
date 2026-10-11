import XCTest
@testable import Allman

final class ExporterTests: XCTestCase {
    func testCSVQuotesAndIncludesLabelsAndNotes() throws {
        let rec = try JSONDecoder().decode(ConversationRecord.self, from: Data(#"{"convId":"2-A","name":"Ada, Lovelace","slug":"ada","headline":"Says \"hi\""}"#.utf8))
        let msg = Message(urn: "urn:li:messagingMessage:1", timestamp: 1_700_000_000_000, fromUrn: nil, fromName: "Ada", isFromMe: false, body: "line one\nline two", reactions: [], attachments: [], originToken: nil, subject: nil)
        let snap = ConversationSnapshot(record: rec, lastMessage: msg)
        var org = Organizer()
        let l = org.addLabel(name: "VIP")
        org.toggle(label: l.id, "2-A")
        org.setNote("met at AIT", "2-A")
        let csv = Exporter.conversationsCSV([snap], organizer: org) { _ in nil }
        let header = csv.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertTrue(header.hasPrefix("name,first_name,last_name,slug,"))
        let row = String(csv.dropFirst(header.count + 1))
        XCTAssertTrue(row.hasPrefix("\"Ada, Lovelace\",,,ada,https://www.linkedin.com/in/ada/,\"Says \"\"hi\"\"\""), row)
        XCTAssertTrue(row.contains(",VIP,met at AIT,"), row)
        XCTAssertTrue(row.contains("\"line one\nline two\",yes,no,,"), row)
        XCTAssertTrue(row.hasSuffix("https://www.linkedin.com/messaging/thread/2-A/\n"), row)
    }

    func testMarkdownThread() throws {
        let rec = try JSONDecoder().decode(ConversationRecord.self, from: Data(#"{"convId":"2-A","name":"Ada","slug":"ada"}"#.utf8))
        let m1 = Message(urn: "u1", timestamp: 1_700_000_000_000, fromUrn: nil, fromName: "Ada", isFromMe: false, body: "Hello", reactions: [], attachments: [], originToken: nil, subject: nil)
        let m2 = Message(urn: "u2", timestamp: 1_700_000_100_000, fromUrn: nil, fromName: nil, isFromMe: true, body: "Hi!", reactions: [Reaction(emoji: "👍", count: 1, hasUserReacted: false)], attachments: [], originToken: nil, subject: nil)
        let md = Exporter.threadMarkdown(ConversationSnapshot(record: rec, lastMessage: m2), messages: [m1, m2], organizer: Organizer(), connection: nil, me: "Sam")
        XCTAssertTrue(md.hasPrefix("# Ada\n"))
        XCTAssertTrue(md.contains("**Ada** ·"))
        XCTAssertTrue(md.contains("**Sam** ·"))
        XCTAssertTrue(md.contains("_👍_"))
    }
}

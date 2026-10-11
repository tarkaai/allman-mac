import XCTest
@testable import Allman

final class OrganizerTests: XCTestCase {
    private func snap(_ id: String, ts: Int64, fromMe: Bool = false) -> ConversationSnapshot {
        let rec = try! JSONDecoder().decode(ConversationRecord.self, from: Data(#"{"convId":"\#(id)","name":"P"}"#.utf8))
        let msg = Message(urn: "urn:li:messagingMessage:\(ts)", timestamp: ts, fromUrn: nil, fromName: nil, isFromMe: fromMe, body: "x", reactions: [], attachments: [], originToken: nil, subject: nil)
        return ConversationSnapshot(record: rec, lastMessage: msg)
    }

    func testLabelsAreManyPerConversationAndDeleteCleansUp() {
        var o = Organizer()
        let hot = o.addLabel(name: "Hot")
        let hiring = o.addLabel(name: "Hiring", color: "green")
        XCTAssertEqual(o.addLabel(name: "hot").id, hot.id, "case-insensitive reuse")
        o.toggle(label: hot.id, "2-A"); o.toggle(label: hiring.id, "2-A"); o.toggle(label: hot.id, "2-B")
        XCTAssertEqual(o.labels(for: "2-A").map(\.name), ["Hot", "Hiring"])
        XCTAssertEqual(o.count(label: hot.id), 2)
        o.toggle(label: hot.id, "2-A")
        XCTAssertEqual(o.labels(for: "2-A").map(\.name), ["Hiring"])
        o.deleteLabel(hiring.id)
        XCTAssertNil(o.labelsByConv["2-A"])
        XCTAssertEqual(o.labels.count, 1)
    }

    func testArchiveResurfacesOnNewerMessage() {
        var o = Organizer()
        let old = snap("2-A", ts: 1_000)
        o.archive(old)
        XCTAssertTrue(o.isArchived(old))
        XCTAssertFalse(o.isArchived(snap("2-A", ts: Int64(Date().timeIntervalSince1970 * 1000) + 60_000)))
        o.unarchive("2-A")
        XCTAssertFalse(o.isArchived(old))
    }

    func testSnoozeHidesUntilDueOrWoken() {
        var o = Organizer()
        let s = snap("2-A", ts: 1_000)
        let later = Date().addingTimeInterval(3600)
        o.setSnooze(s, until: later, hidden: true)
        XCTAssertTrue(o.isSnoozed(s))
        XCTAssertFalse(o.isSnoozed(s, now: later.addingTimeInterval(1)), "due → visible")
        XCTAssertTrue(o.isDue("2-A", now: later))
        XCTAssertFalse(o.isSnoozed(snap("2-A", ts: 2_000)), "a newer message wakes it")
        XCTAssertTrue(o.isWoken(snap("2-A", ts: 2_000)))
        // A reminder (not hidden) never hides.
        o.setSnooze(s, until: later, hidden: false, note: "ask about the deck")
        XCTAssertFalse(o.isSnoozed(s))
        XCTAssertEqual(o.snooze("2-A")?.note, "ask about the deck")
        // Due snoozes fire once.
        o.setSnooze(s, until: Date().addingTimeInterval(-1), hidden: true)
        XCTAssertEqual(o.takeDue(), ["2-A"])
        XCTAssertEqual(o.takeDue(), [])
    }

    func testPresetsAreInTheFutureAndOrdered() {
        let p = Snooze.presets()
        XCTAssertTrue(p.allSatisfy { $0.date > Date() })
        XCTAssertEqual(p.map(\.date), p.map(\.date).sorted())
    }

    func testRoundTripsThroughJSON() throws {
        var o = Organizer()
        o.addLabel(name: "VIP")
        o.setNote("met at AIT", "2-A")
        o.setNote("   ", "2-B")
        let data = try JSONEncoder().encode(o)
        let back = try JSONDecoder().decode(Organizer.self, from: data)
        XCTAssertEqual(back.labels.map(\.name), ["VIP"])
        XCTAssertEqual(back.note("2-A"), "met at AIT")
        XCTAssertEqual(back.note("2-B"), "")
    }
}

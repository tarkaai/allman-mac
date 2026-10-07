import XCTest
@testable import Allman

final class ReadStateTests: XCTestCase {
    private func snapshot(lastFromMe: Bool, ts: Int64, unreadCount: Int = 0, read: Bool = true) -> ConversationSnapshot {
        let json = """
        {"convId":"2-C","name":"Jamie","unreadCount":\(unreadCount),"read":\(read)}
        """
        let rec = try! JSONDecoder().decode(ConversationRecord.self, from: Data(json.utf8))
        let msg = Message(urn: "urn:li:messagingMessage:\(ts)", timestamp: ts, fromUrn: "x", fromName: "Jamie", isFromMe: lastFromMe, body: "hi", reactions: [], attachments: [], originToken: nil, subject: nil)
        return ConversationSnapshot(record: rec, lastMessage: msg)
    }

    func testOldReadThreadsAreNotUnreadOnFirstLaunch() {
        var state = ReadState()
        state.baseline = 1_000_000
        XCTAssertFalse(state.isUnread(snapshot(lastFromMe: false, ts: 900_000)))
    }

    func testLinkedInUnreadCountsAsUnread() {
        var state = ReadState()
        state.baseline = 1_000_000
        XCTAssertTrue(state.isUnread(snapshot(lastFromMe: false, ts: 900_000, unreadCount: 2)))
        XCTAssertTrue(state.isUnread(snapshot(lastFromMe: false, ts: 900_000, read: false)))
    }

    func testNewInboundAfterBaselineIsUnreadUntilSeen() {
        var state = ReadState()
        state.baseline = 1_000_000
        let snap = snapshot(lastFromMe: false, ts: 2_000_000)
        XCTAssertTrue(state.isUnread(snap))
        state.markSeen("2-C", at: 2_000_000)
        XCTAssertFalse(state.isUnread(snap))
        // A newer reply flips it back.
        XCTAssertTrue(state.isUnread(snapshot(lastFromMe: false, ts: 3_000_000)))
    }

    func testOwnReplyIsNeverUnread() {
        var state = ReadState()
        state.baseline = 0
        XCTAssertFalse(state.isUnread(snapshot(lastFromMe: true, ts: 5_000_000, unreadCount: 3, read: false)))
    }

    func testNotifiedRingBufferIsBounded() {
        var state = ReadState()
        for i in 0..<600 { state.rememberNotified("m\(i)") }
        XCTAssertEqual(state.notified.count, 500)
        XCTAssertFalse(state.hasNotified("m0"))
        XCTAssertTrue(state.hasNotified("m599"))
    }
}

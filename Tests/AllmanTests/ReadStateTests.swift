import XCTest
@testable import Allman

final class ReadStateTests: XCTestCase {
    private func snapshot(lastFromMe: Bool, ts: Int64, unreadCount: Int = 0, read: Bool = true, inbound: [Int64]? = nil, lastReadAt: String? = nil) -> ConversationSnapshot {
        let lr = lastReadAt.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"convId":"2-C","name":"Jamie","unreadCount":\(unreadCount),"read":\(read),"lastReadAt":\(lr)}
        """
        let rec = try! JSONDecoder().decode(ConversationRecord.self, from: Data(json.utf8))
        let msg = Message(urn: "urn:li:messagingMessage:\(ts)", timestamp: ts, fromUrn: "x", fromName: "Jamie", isFromMe: lastFromMe, body: "hi", reactions: [], attachments: [], originToken: nil, subject: nil)
        return ConversationSnapshot(record: rec, lastMessage: msg, inboundTimestamps: inbound ?? (lastFromMe ? [] : [ts]))
    }

    func testUnreadCountCountsInboundSinceWatermark() {
        var state = ReadState()
        state.baseline = 0
        // Three inbound after the LinkedIn read marker, one before.
        let snap = snapshot(lastFromMe: false, ts: 5_000_000, read: false, inbound: [1_000_000, 3_000_000, 4_000_000, 5_000_000], lastReadAt: "1970-01-01T00:33:20.000Z") // 2_000_000 ms
        XCTAssertEqual(state.unreadCount(snap), 3)
        state.markSeen("2-C", at: 4_000_000)
        XCTAssertEqual(state.unreadCount(snap), 1)
        state.markSeen("2-C", at: 5_000_000)
        XCTAssertEqual(state.unreadCount(snap), 0)
    }

    func testUnreadCountFallsBackToLinkedInCount() {
        var state = ReadState()
        state.baseline = 0
        let snap = snapshot(lastFromMe: false, ts: 5_000_000, unreadCount: 2, read: false, inbound: [])
        XCTAssertEqual(state.unreadCount(snap), 2)
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

final class PinTests: XCTestCase {
    func testToggleMoveAndCap() {
        var s = ReadState()
        for i in 0..<ReadState.maxPins { s.togglePin("c\(i)") }
        XCTAssertEqual(s.pins.count, ReadState.maxPins)
        s.togglePin("overflow")
        XCTAssertFalse(s.isPinned("overflow"), "cap holds")
        s.togglePin("c0")
        XCTAssertFalse(s.isPinned("c0"))
        s.togglePin("overflow")
        XCTAssertTrue(s.isPinned("overflow"))
        s.movePin("overflow", to: 0)
        XCTAssertEqual(s.pins.first, "overflow")
    }

    func testDecodesWithoutPinsKey() throws {
        let data = Data(#"{"seenAt":{},"baseline":1,"notified":[]}"#.utf8)
        let s = try JSONDecoder().decode(ReadState.self, from: data)
        XCTAssertEqual(s.pins, [])
    }
}

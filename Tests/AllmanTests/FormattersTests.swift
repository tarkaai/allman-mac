import XCTest
@testable import Allman

final class FormattersTests: XCTestCase {
    func testRelative() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-2), now: now), "now")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-45), now: now), "45s")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-5 * 60), now: now), "5m")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-3 * 3600), now: now), "3h")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-2 * 86400), now: now), "2d")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-15 * 86400), now: now), "2w")
        XCTAssertEqual(Fmt.relative(nil, now: now), "")
    }

    func testRelativeSentence() {
        let now = Date()
        XCTAssertEqual(Fmt.relativeSentence(nil), "never")
        XCTAssertEqual(Fmt.relativeSentence(now, now: now), "just now")
        XCTAssertEqual(Fmt.relativeSentence(now.addingTimeInterval(-120), now: now), "2m ago")
    }

    func testDayLabel() {
        let now = Date()
        XCTAssertEqual(Fmt.dayLabel(now, now: now), "Today")
        XCTAssertEqual(Fmt.dayLabel(now.addingTimeInterval(-86400), now: now), "Yesterday")
    }

    func testInitials() {
        XCTAssertEqual(Fmt.initials("Jamie Rivera"), "JR")
        XCTAssertEqual(Fmt.initials("Dr. Oshin Behl, MBBS"), "OB")
        XCTAssertEqual(Fmt.initials("madonna"), "M")
    }

    func testAttachmentSummaries() {
        let a = Attachment(type: "video", url: nil, name: nil, size: nil, mimeType: nil, previewUrl: nil, width: nil, height: nil, durationMs: 83_000, title: nil, description: nil, originalText: nil, authorName: nil)
        XCTAssertEqual(a.summary, "Video · 1m 23s")
        let f = Attachment(type: "file", url: nil, name: "deck.pdf", size: nil, mimeType: nil, previewUrl: nil, width: nil, height: nil, durationMs: nil, title: nil, description: nil, originalText: nil, authorName: nil)
        XCTAssertEqual(f.summary, "File: deck.pdf")
    }
}

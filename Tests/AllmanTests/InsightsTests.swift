import XCTest
@testable import Allman

final class InsightsTests: XCTestCase {
    func testRangesStartAtMidnightByCalendarDays() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15, minute: 30))!
        let week = InsightsRange.week.since(now: now, custom: 0, calendar: cal)!
        XCTAssertEqual(cal.dateComponents([.year, .month, .day, .hour], from: week), DateComponents(year: 2026, month: 10, day: 5, hour: 0))
        let day = InsightsRange.day.since(now: now, custom: 0, calendar: cal)!
        XCTAssertEqual(cal.component(.day, from: day), 11)
        XCTAssertEqual(cal.component(.hour, from: day), 0)
        XCTAssertNil(InsightsRange.allTime.since(now: now, custom: 0, calendar: cal))
        XCTAssertEqual(InsightsRange.custom.days(custom: 14), 14)
        XCTAssertEqual(InsightsRange.custom.days(custom: 0), 1, "at least one day")
    }

    func testWindowNarrowsTheNumbers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("allman-insights-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try MockStore.make(at: root)
        let reader = StoreReader(storeURL: root)
        let account = try XCTUnwrap(reader.discoverAccounts().first)
        let snaps = reader.loadAll(accountDir: account.dir)
        let all = Insights.compute(reader: reader, accountDir: account.dir, snapshots: snaps, since: nil)
        let day = Insights.compute(reader: reader, accountDir: account.dir, snapshots: snaps, since: InsightsRange.day.since(custom: 0))
        XCTAssertGreaterThan(all.sent + all.received, day.sent + day.received, "a day holds fewer messages than all time")
        XCTAssertEqual(all.totalThreads, day.totalThreads, "stored totals don't depend on the window")
        XCTAssertEqual(day.bucketUnit, .day)
        XCTAssertEqual(all.bucketUnit, .weekOfYear)
        XCTAssertEqual(day.buckets.count, 2, "today and yesterday")
    }
}

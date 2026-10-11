import XCTest
@testable import Allman

final class SearchRankTests: XCTestCase {
    func testExactAndPrefixBeatContains() {
        let aj = SearchRank.score(name: "AJ Sample", secondary: [nil], query: "aj")
        let anthony = SearchRank.score(name: "Anthony Jones", secondary: [nil], query: "aj")
        let raj = SearchRank.score(name: "Raj Patel", secondary: [nil], query: "aj")
        XCTAssertGreaterThan(aj, anthony, "name prefix beats initials")
        XCTAssertGreaterThan(anthony, raj, "initials beat substring")
        XCTAssertGreaterThan(raj, 0)
        XCTAssertEqual(SearchRank.score(name: "Zoe", secondary: [nil], query: "aj"), 0)
    }

    func testEveryTokenMustMatchAndSecondaryFieldsCount() {
        XCTAssertEqual(SearchRank.score(name: "Sam Lee", secondary: ["Acme"], query: "sam zzz"), 0)
        XCTAssertGreaterThan(SearchRank.score(name: "Sam Lee", secondary: ["Acme"], query: "sam acme"), 0)
        let byName = SearchRank.score(name: "Acme Person", secondary: [nil], query: "acme")
        let byCompany = SearchRank.score(name: "Sam Lee", secondary: ["Acme"], query: "acme")
        XCTAssertGreaterThan(byName, byCompany)
    }
}

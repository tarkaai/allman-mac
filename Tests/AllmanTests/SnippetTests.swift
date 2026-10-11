import XCTest
@testable import Allman

final class SnippetTests: XCTestCase {
    func testRenderFillsKnownAndKeepsUnknown() {
        let vars = ["firstName": "Sam", "company": "Acme"]
        XCTAssertEqual(Snippet.render("Hi {firstName} at {company}!", vars: vars), "Hi Sam at Acme!")
        XCTAssertEqual(Snippet.render("Hi {Name} {x-y} {", vars: vars), "Hi {Name} {x-y} {")
        XCTAssertEqual(Snippet.render("{firstName}{firstName}", vars: vars), "SamSam")
        XCTAssertEqual(Snippet.render("no braces", vars: [:]), "no braces")
    }

    @MainActor
    func testSeedsFromTuiFileAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tui = dir.appendingPathComponent("templates.json")
        try #"[{"id":"t-1","name":"Follow up","body":"Hey {firstName}!","createdAt":"2026-01-01T00:00:00.000Z"}]"#.write(to: tui, atomically: true, encoding: .utf8)
        let mine = dir.appendingPathComponent("snippets.json")
        let store = SnippetStore(fileURL: mine, seedFrom: tui)
        XCTAssertEqual(store.snippets.map(\.name), ["Follow up"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path))
        store.add(name: "Thanks", body: "Thanks {name}")
        store.update("t-1", name: "Follow-up", body: "Hey {firstName}!!")
        let again = SnippetStore(fileURL: mine, seedFrom: nil)
        XCTAssertEqual(again.snippets.map(\.name), ["Follow-up", "Thanks"])
        XCTAssertEqual(again.importFile(tui), 1, "the old body is new again after the edit")
        again.remove("t-1")
        XCTAssertEqual(SnippetStore(fileURL: mine, seedFrom: nil).snippets.count, 2)
    }
}

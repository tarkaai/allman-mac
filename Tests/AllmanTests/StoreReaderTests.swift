import XCTest
@testable import Allman

final class StoreReaderTests: XCTestCase {
    private var fixtures: URL { Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures") }

    /// Builds a throwaway store: {store}/{profileId}/{convId}/{RECORD.json,messages/…} + slug symlinks.
    private func makeStore() throws -> (store: URL, accountDir: URL) {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("allman-test-\(UUID().uuidString)")
        let account = store.appendingPathComponent("ACoAAME")
        let conv = account.appendingPathComponent("2-TESTCONV==")
        try FileManager.default.createDirectory(at: conv.appendingPathComponent("messages"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("RECORD.json"), to: conv.appendingPathComponent("RECORD.json"))
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("2026-10.jsonl"), to: conv.appendingPathComponent("messages/2026-10.jsonl"))
        let auth = """
        {"urn":"urn:li:fsd_profile:ACoAAME","profileSlug":null,"name":null,"headline":null,"profileUrl":null,"imageUrl":null,"userType":null,"networkSize":null,"status":"authenticated","lastSyncAt":"2026-10-07T17:48:57.401Z"}
        """
        try auth.write(to: account.appendingPathComponent("AUTH.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: store.appendingPathComponent("sam-example"), withDestinationURL: URL(fileURLWithPath: "ACoAAME"))
        try FileManager.default.createSymbolicLink(at: account.appendingPathComponent("jamie-rivera"), withDestinationURL: URL(fileURLWithPath: "2-TESTCONV=="))
        return (store, account)
    }

    func testDiscoverAccountsUsesSlugSymlink() throws {
        let (store, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let accounts = StoreReader(storeURL: store).discoverAccounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.slug, "sam-example")
        XCTAssertEqual(accounts.first?.profileId, "ACoAAME")
        XCTAssertTrue(accounts.first?.auth.isAuthenticated ?? false)
        XCTAssertEqual(accounts.first?.displayName, "sam-example", "falls back to slug when AUTH.name is null")
    }

    func testConversationIdsSkipSymlinks() throws {
        let (store, account) = try makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        XCTAssertEqual(StoreReader(storeURL: store).conversationIds(accountDir: account), ["2-TESTCONV=="])
    }

    func testRecordDecodesAndDerivesFields() throws {
        let (store, account) = try makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let rec = try XCTUnwrap(StoreReader(storeURL: store).readRecord(accountDir: account, convId: "2-TESTCONV=="))
        XCTAssertEqual(rec.displayName, "Jamie Rivera")
        XCTAssertEqual(rec.sendTarget, "jamie-rivera")
        XCTAssertEqual(rec.avatarURL?.absoluteString, "https://example.com/200.jpg", "picks the ~200px rendition")
        XCTAssertEqual(rec.linkedInProfileURL?.absoluteString, "https://www.linkedin.com/in/jamie-rivera/")
        XCTAssertNotNil(rec.lastActivityDate)
    }

    func testMessagesParseDedupeAndIgnoreJunk() throws {
        let (store, account) = try makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let msgs = StoreReader(storeURL: store).readMessages(accountDir: account, convId: "2-TESTCONV==")
        XCTAssertEqual(msgs.map(\.urn), [
            "urn:li:messagingMessage:2-MSG1",
            "urn:li:messagingMessage:2-MSG2", // fs_event + messagingMessage forms collapse; last write wins
            "urn:li:messagingMessage:2-MSG3",
        ])
        XCTAssertEqual(msgs[1].body, "Shared with commentary")
        XCTAssertEqual(msgs[2].previewText, "Sure — Thursday works.\nTalk then!")
    }

    func testLastMessageAndSnapshot() throws {
        let (store, account) = try makeStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let snap = try XCTUnwrap(StoreReader(storeURL: store).loadSnapshot(accountDir: account, convId: "2-TESTCONV=="))
        XCTAssertEqual(snap.lastMessage?.urn, "urn:li:messagingMessage:2-MSG3")
        XCTAssertEqual(snap.activityDate, snap.lastMessage?.date)
    }

    func testAttachmentSummaryIgnoresRaw() {
        let line = #"{"urn":"u","timestamp":1,"fromUrn":"x","fromName":"y","isFromMe":false,"body":"","reactions":[],"attachments":[{"type":"post_share","authorName":"Ada","raw":{"a":[1,2,{"b":null}]}}],"originToken":null}"#
        let msgs = StoreReader.parseJSONL(data: Data(line.utf8))
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].previewText, "Shared a post by Ada")
    }

    func testBareMessageId() {
        XCTAssertEqual(StoreReader.bareMessageId("urn:li:fs_event:(2-CONV,2-MSG)"), "2-MSG")
        XCTAssertEqual(StoreReader.bareMessageId("urn:li:messagingMessage:2-MSG"), "2-MSG")
        XCTAssertEqual(StoreReader.bareMessageId("2-MSG"), "2-MSG")
    }
}

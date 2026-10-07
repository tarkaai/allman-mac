import XCTest
@testable import Allman

final class CLIEventsTests: XCTestCase {
    func testListenMessageReceived() throws {
        let line = #"{"event":"message.received","account":"ACo","timestamp":1791126000000,"conversation":{"urn":"urn:li:msg_conversation:(a,2-C)","convId":"2-C","name":"Jamie Rivera","slug":"jamie-rivera"},"from":{"urn":"urn:li:fsd_profile:X","name":"Jamie Rivera"},"message":{"urn":"urn:li:messagingMessage:2-M","body":"hello","isFromMe":false}}"#
        let ev = try XCTUnwrap(NDJSON.decode(line, as: ListenEvent.self))
        XCTAssertEqual(ev.event, "message.received")
        XCTAssertEqual(ev.conversation?.convId, "2-C")
        XCTAssertEqual(ev.from?.name, "Jamie Rivera")
        XCTAssertEqual(ev.message?.body, "hello")
        XCTAssertEqual(ev.date.timeIntervalSince1970, 1791126000, accuracy: 0.001)
    }

    func testListenHeartbeatAndConnected() throws {
        XCTAssertEqual(NDJSON.decode(#"{"event":"heartbeat","account":"ACo","timestamp":1}"#, as: ListenEvent.self)?.event, "heartbeat")
        let c = try XCTUnwrap(NDJSON.decode(#"{"event":"connected","account":"ACo","connectionId":"abc","timestamp":1}"#, as: ListenEvent.self))
        XCTAssertEqual(c.connectionId, "abc")
    }

    func testSyncEvents() throws {
        let complete = try XCTUnwrap(NDJSON.decode(#"{"event":"sync.complete","scope":"inbox","account":"ACo","conversationsSynced":12,"messagesSynced":40}"#, as: SyncEvent.self))
        XCTAssertEqual(complete.conversationsSynced, 12)
        XCTAssertEqual(complete.messagesSynced, 40)
        let progress = try XCTUnwrap(NDJSON.decode(#"{"event":"sync.conversation.progress","convId":"2-C","slug":null,"messagesFetched":7,"oldestMessageAt":null,"newestMessageAt":5}"#, as: SyncEvent.self))
        XCTAssertEqual(progress.messagesFetched, 7)
        XCTAssertNil(progress.slug)
    }

    func testGarbageLinesAreIgnored() {
        XCTAssertNil(NDJSON.decode("Listening for messages...", as: ListenEvent.self))
        XCTAssertNil(NDJSON.decode("", as: ListenEvent.self))
    }

    func testAuthFailureDetection() {
        XCTAssertTrue(AllmanError(command: "listen", exitCode: 1, stderr: "Error: Account not authenticated. Run `allman login`.").looksLikeAuthFailure)
        XCTAssertTrue(AllmanError(command: "sync", exitCode: 1, stderr: "LinkedIn session expired. Run `allman login` to re-authenticate.").looksLikeAuthFailure)
        XCTAssertFalse(AllmanError(command: "sync", exitCode: 1, stderr: "ECONNRESET").looksLikeAuthFailure)
    }
}

import XCTest
@testable import Allman

/// The window's layout rules (docs/UI-RULES.md), proven on mock data: this launches a
/// second copy of the app on a synthetic store with the fake CLI, lets it drive its own
/// window (UIRuleChecks: real toolbar, clicks, key presses, scroll views) and asserts
/// every verdict it reports. Screenshots of each state land in the test's temp dir.
final class UIRulesTests: XCTestCase {
    func testWindowFollowsTheRules() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("allman-uicheck-\(UUID().uuidString)")
        let store = tmp.appendingPathComponent("store")
        let support = tmp.appendingPathComponent("support")
        let shots = tmp.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try MockStore.make(at: store)

        // The host of this test bundle is the app itself; launch another instance of it.
        let app = Bundle.main.executableURL!
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fake = repo.appendingPathComponent("scripts/fake-allman.sh")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fake.path), "fake CLI missing at \(fake.path)")
        let out = tmp.appendingPathComponent("result.json")

        let p = Process()
        p.executableURL = app
        // A clean environment: the test host's XCTest/DYLD injection variables must not reach the child.
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for k in ["PATH", "HOME", "TMPDIR", "USER", "LANG", "SHELL"] { if let v = inherited[k] { env[k] = v } }
        env["ALLMAN_STORE"] = store.path
        env["ALLMAN_BIN"] = fake.path
        env["ALLMAN_APPSUPPORT"] = support.path
        env["ALLMAN_UICHECK_OUT"] = out.path
        env["ALLMAN_UICHECK_SHOTS"] = shots.path
        env["FAKE_SEND_DELAY"] = "3"          // the CLI returns here…
        env["FAKE_SEND_WRITE_DELAY"] = "0.4"  // …but the message lands in the store here, like the real one
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try p.run()
        defer { if p.isRunning { p.terminate() } }

        let deadline = Date().addingTimeInterval(120)
        while !FileManager.default.fileExists(atPath: out.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "the app never wrote \(out.path)")
        let data = try Data(contentsOf: out)
        let report = try JSONDecoder().decode(UIRuleChecks.Report.self, from: data)
        XCTAssertTrue(report.ready, "checks did not finish: \(report.error ?? "?")")
        XCTAssertFalse(report.checks.isEmpty)
        print("UI rules on mock data (screenshots: \(shots.path))")
        for c in report.checks { print("  \(c.pass ? "PASS" : "FAIL") [\(c.rule)] \(c.name)\(c.detail.isEmpty ? "" : " — \(c.detail)")") }
        let failed = report.checks.filter { !$0.pass }
        XCTAssertTrue(failed.isEmpty, "failed: " + failed.map { "[\($0.rule)] \($0.name) (\($0.detail))" }.joined(separator: "; "))
    }
}

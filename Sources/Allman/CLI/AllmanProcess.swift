// The one place the app spawns `allman`. Every invocation gets `--store <path>`
// (and ALLMAN_STORE in the environment) so nothing ever lands in a
// cwd-relative `.allman/`. stdout is parsed as NDJSON when streaming; stderr
// is captured for error reporting.

import Foundation
import os

let cliLog = Logger(subsystem: "sh.allman.mac", category: "cli")

struct AllmanError: LocalizedError {
    let command: String
    let exitCode: Int32
    let stderr: String
    var errorDescription: String? { friendlyMessage }

    /// One short, human line — never a git/stack dump.
    var friendlyMessage: String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if isGitLock { return "The store was busy (another allman command was writing). Please try again." }
        if looksLikeAuthFailure { return "LinkedIn session expired. Sign in again from the menu bar." }
        if let rate = lines.first(where: { $0.lowercased().contains("rate limit") || $0.contains("429") }) { return String(rate.prefix(140)) }
        // Prefer the CLI's own "✗ …" error line, else the last non-noise line.
        let candidate = lines.last(where: { $0.hasPrefix("✗") })
            ?? lines.last(where: { !$0.lowercased().hasPrefix("fatal:") && !$0.hasPrefix("at ") && !$0.contains("node_modules") })
            ?? lines.last
        guard var msg = candidate else { return "allman \(command) exited \(exitCode)" }
        if msg.hasPrefix("✗") { msg = msg.dropFirst().trimmingCharacters(in: .whitespaces) }
        if msg.lowercased().hasPrefix("error:") { msg = msg.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        return msg.count > 160 ? String(msg.prefix(157)) + "…" : msg
    }

    /// Two allman processes committing at once (e.g. a reaction while `listen` writes).
    var isGitLock: Bool {
        let s = stderr.lowercased()
        return s.contains("index.lock") || s.contains("unable to create") && s.contains(".lock") || s.contains("another git process")
    }

    /// Worth an automatic retry: store contention or a flaky network hop.
    var isTransient: Bool {
        if isGitLock { return true }
        let s = stderr.lowercased()
        return s.contains("econnreset") || s.contains("etimedout") || s.contains("socket hang up") || s.contains("http 429") || s.contains("http 5")
    }
    /// The CLI's wording when cookies are gone or stale.
    var looksLikeAuthFailure: Bool {
        let s = stderr.lowercased()
        return s.contains("allman login") || s.contains("not authenticated") || s.contains("session expired") || s.contains("401")
    }
}

struct AllmanBinaryMissing: LocalizedError {
    var errorDescription: String? {
        "The allman CLI was not found. Install it (curl -fsSL https://allman.sh/install.sh | bash) or set its path in Settings."
    }
}

/// A running `allman` subprocess with line-oriented stdout.
final class AllmanProcess: @unchecked Sendable {
    let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var stdoutBuffer = Data()
    private(set) var stderrText = ""
    private let lock = NSLock()

    var onLine: ((String) -> Void)?
    var onStderr: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?

    let arguments: [String]

    init(binary: URL, arguments: [String], storeURL: URL, account: String?) {
        var argv: [String] = []
        if let account { argv += ["--account", account] }
        argv += ["--store", storeURL.path]
        argv += arguments
        self.arguments = argv

        process.executableURL = binary
        process.arguments = argv
        var env = ProcessInfo.processInfo.environment
        env["ALLMAN_STORE"] = storeURL.path
        // Playwright (login) and bun need HOME; GUI launches sometimes lack a sane PATH.
        let extraPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", (env["HOME"] ?? "") + "/.local/bin"]
        env["PATH"] = (extraPath + (env["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        process.environment = env
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
    }

    func start() throws {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            if data.isEmpty { h.readabilityHandler = nil; return }
            self.consume(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.lock(); self.stderrText += text; self.lock.unlock()
            self.onStderr?(text)
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            // Drain anything left in the pipes before reporting.
            let rest = self.stdout.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { self.consume(rest) }
            self.flushPartialLine()
            let errRest = self.stderr.fileHandleForReading.readDataToEndOfFile()
            if !errRest.isEmpty {
                let t = String(decoding: errRest, as: UTF8.self)
                self.lock.lock(); self.stderrText += t; self.lock.unlock()
            }
            self.stdout.fileHandleForReading.readabilityHandler = nil
            self.stderr.fileHandleForReading.readabilityHandler = nil
            self.lock.lock(); let err = self.stderrText; self.lock.unlock()
            ChildRegistry.shared.unregister(p.processIdentifier)
            cliLog.notice("pid \(p.processIdentifier) exited status \(p.terminationStatus) reason \(p.terminationReason == .uncaughtSignal ? "signal" : "exit", privacy: .public) (\(self.arguments.last ?? "", privacy: .public))")
            self.onExit?(p.terminationStatus, err)
        }
        try process.run()
        ChildRegistry.shared.register(process.processIdentifier)
        cliLog.notice("spawned pid \(self.process.processIdentifier) allman \(self.arguments.joined(separator: " "), privacy: .public)")
    }

    func terminate() {
        guard process.isRunning else { return }
        cliLog.notice("terminating pid \(self.process.processIdentifier) (\(self.arguments.last ?? "", privacy: .public))")
        process.terminate() // SIGTERM — the CLI handles it and aborts its SSE stream
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning {
                cliLog.warning("pid \(process.processIdentifier) ignored SIGTERM, sending SIGKILL")
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        stdoutBuffer.append(data)
        var lines: [String] = []
        while let nl = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    private func flushPartialLine() {
        lock.lock()
        let rest = String(decoding: stdoutBuffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        stdoutBuffer.removeAll()
        lock.unlock()
        if !rest.isEmpty { onLine?(rest) }
    }
}

/// Convenience runner used by the UI for one-shot commands (send, react, sync <conv>).
enum AllmanRunner {
    struct Context {
        let storeURL: URL
        let account: String?
    }

    /// Runs to completion and returns stdout. Throws AllmanError on non-zero exit.
    static func run(_ arguments: [String], context: Context, timeout: TimeInterval = 120) async throws -> String {
        guard let bin = AllmanBinary.resolve() else { throw AllmanBinaryMissing() }
        let proc = AllmanProcess(binary: bin, arguments: arguments, storeURL: context.storeURL, account: context.account)
        var out: [String] = []
        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            let finishLock = NSLock()
            proc.onLine = { out.append($0) }
            proc.onExit = { code, err in
                finishLock.lock(); defer { finishLock.unlock() }
                guard !finished else { return }
                finished = true
                if code == 0 {
                    cont.resume(returning: out.joined(separator: "\n"))
                } else {
                    cont.resume(throwing: AllmanError(command: arguments.first ?? "", exitCode: code, stderr: err))
                }
            }
            do { try proc.start() } catch {
                finishLock.lock(); defer { finishLock.unlock() }
                guard !finished else { return }
                finished = true
                cont.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finishLock.lock()
                let done = finished
                finishLock.unlock()
                if !done { proc.terminate() }
            }
        }
    }

    /// `run` with automatic retries for transient failures (git lock, network blips).
    static func runWithRetry(_ arguments: [String], context: Context, timeout: TimeInterval = 120, attempts: Int = 4) async throws -> String {
        var delay: UInt64 = 400
        for attempt in 1...attempts {
            do {
                return try await run(arguments, context: context, timeout: timeout)
            } catch let err as AllmanError where err.isTransient && attempt < attempts {
                cliLog.notice("allman \(arguments.first ?? "", privacy: .public) transient failure (attempt \(attempt)): retrying in \(delay)ms")
                try? await Task.sleep(for: .milliseconds(delay))
                delay = min(delay * 2, 3000)
            }
        }
        return try await run(arguments, context: context, timeout: timeout)
    }

    static func runJSON<T: Decodable>(_ arguments: [String], as type: T.Type, context: Context, timeout: TimeInterval = 120) async throws -> T {
        let raw = try await runWithRetry(arguments, context: context, timeout: timeout)
        // Commands print exactly one JSON document in --json mode; take the last line that parses.
        for line in raw.split(separator: "\n").reversed() {
            if let data = line.data(using: .utf8), let v = try? JSONDecoder().decode(T.self, from: data) { return v }
        }
        if let data = raw.data(using: .utf8), let v = try? JSONDecoder().decode(T.self, from: data) { return v }
        throw AllmanError(command: arguments.first ?? "", exitCode: 0, stderr: "unexpected output: \(raw.prefix(200))")
    }
}


/// Remembers the PIDs we spawned so a crashed or force-quit app can reap its
/// orphaned `allman listen`/`sync` children on the next launch. macOS has no
/// parent-death signal, so without this a `kill -9 Allman` leaves them running.
final class ChildRegistry: @unchecked Sendable {
    static let shared = ChildRegistry()
    private let url = StorePaths.appSupportURL.appendingPathComponent("children.json")
    private let lock = NSLock()

    private func load() -> [Int32] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Int32].self, from: data)) ?? []
    }

    private func save(_ pids: [Int32]) {
        try? JSONEncoder().encode(pids).write(to: url, options: .atomic)
    }

    func register(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        var pids = load(); if !pids.contains(pid) { pids.append(pid) }; save(pids)
    }

    func unregister(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        save(load().filter { $0 != pid })
    }

    /// Kill recorded children from a previous run that are still alive and still allman.
    func reapOrphans() {
        lock.lock(); defer { lock.unlock() }
        var survivors: [Int32] = []
        for pid in load() {
            guard kill(pid, 0) == 0 else { continue } // gone
            var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
            let n = proc_pidpath(pid, &buf, UInt32(buf.count))
            let path = n > 0 ? String(cString: buf) : ""
            guard path.hasSuffix("/allman") else { continue } // PID reused by something else
            cliLog.warning("reaping orphaned allman pid \(pid) from a previous run")
            kill(pid, SIGTERM)
            survivors.append(pid)
        }
        save([])
        if !survivors.isEmpty {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                for pid in survivors where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
    }
}

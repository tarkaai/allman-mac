// The one place the app spawns `allman`. Every invocation gets `--store <path>`
// (and ALLMAN_STORE in the environment) so nothing ever lands in a
// cwd-relative `.allman/`. stdout is parsed as NDJSON when streaming; stderr
// is captured for error reporting.

import Foundation

struct AllmanError: LocalizedError {
    let command: String
    let exitCode: Int32
    let stderr: String
    var errorDescription: String? {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "allman \(command) exited \(exitCode)" : detail
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
            self.onExit?(p.terminationStatus, err)
        }
        try process.run()
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate() // SIGTERM — the CLI handles it and aborts its SSE stream
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
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

    static func runJSON<T: Decodable>(_ arguments: [String], as type: T.Type, context: Context, timeout: TimeInterval = 120) async throws -> T {
        let raw = try await run(arguments, context: context, timeout: timeout)
        // Commands print exactly one JSON document in --json mode; take the last line that parses.
        for line in raw.split(separator: "\n").reversed() {
            if let data = line.data(using: .utf8), let v = try? JSONDecoder().decode(T.self, from: data) { return v }
        }
        if let data = raw.data(using: .utf8), let v = try? JSONDecoder().decode(T.self, from: data) { return v }
        throw AllmanError(command: arguments.first ?? "", exitCode: 0, stderr: "unexpected output: \(raw.prefix(200))")
    }
}

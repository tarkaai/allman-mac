// Full-text search over every stored message (what `allman grep` does), run
// off the main thread straight from the JSONL files. A raw case-insensitive
// line scan screens out most lines before any JSON is decoded.

import Foundation

/// One message that matched a search, with the conversation it lives in.
struct MessageHit: Identifiable, Hashable {
    let convId: String
    let message: Message
    var id: String { "msg:\(message.urn)" }

    /// A short window of the body around the first match, newlines collapsed.
    func snippet(for query: String, before: Int = 36, after: Int = 90) -> String {
        let body = message.body.replacingOccurrences(of: "\n", with: " ")
        guard let r = body.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(body.prefix(after + before))
        }
        let start = body.index(r.lowerBound, offsetBy: -before, limitedBy: body.startIndex) ?? body.startIndex
        let end = body.index(r.upperBound, offsetBy: after, limitedBy: body.endIndex) ?? body.endIndex
        var s = String(body[start..<end])
        if start > body.startIndex { s = "…" + s }
        if end < body.endIndex { s += "…" }
        return s
    }
}

extension StoreReader {
    /// Every message whose body contains `query` (case- and diacritic-insensitive),
    /// newest first, capped at `limit`. Scans all conversations in parallel.
    func searchMessages(accountDir: URL, query: String, limit: Int = 200, isCancelled: @escaping @Sendable () -> Bool = { false }) -> [MessageHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let ids = conversationIds(accountDir: accountDir)
        var buckets = [[MessageHit]](repeating: [], count: ids.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: ids.count) { i in
            if isCancelled() { return }
            let hits = Self.scan(accountDir: accountDir, convId: ids[i], needle: needle)
            guard !hits.isEmpty else { return }
            lock.lock(); buckets[i] = hits; lock.unlock()
        }
        if isCancelled() { return [] }
        let all = buckets.flatMap { $0 }.sorted { $0.message.timestamp > $1.message.timestamp }
        var seen = Set<String>()
        var out: [MessageHit] = []
        for h in all where seen.insert(Self.bareMessageId(h.message.urn)).inserted {
            out.append(h)
            if out.count >= limit { break }
        }
        return out
    }

    private static func scan(accountDir: URL, convId: String, needle: String) -> [MessageHit] {
        let dir = accountDir.appendingPathComponent(convId).appendingPathComponent("messages")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var hits: [MessageHit] = []
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        for file in files where file.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: file) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                // Cheap screen on the raw line (body is inside it) before decoding JSON.
                let raw = String(decoding: line, as: UTF8.self)
                guard raw.range(of: needle, options: opts) != nil else { continue }
                guard let m = try? decoder.decode(Message.self, from: Data(line)),
                      m.body.range(of: needle, options: opts) != nil else { continue }
                hits.append(MessageHit(convId: convId, message: m))
            }
        }
        return hits
    }
}

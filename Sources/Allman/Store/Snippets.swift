// Saved replies with {placeholders}, shared across accounts. Same JSON shape
// as allman-tui's templates ({id, name, body, createdAt}); the first launch
// seeds from the TUI's file when there is one, so both front-ends start equal.

import Foundation
import Observation

struct Snippet: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var body: String
    var createdAt: String

    init(id: String = UUID().uuidString, name: String, body: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.body = body
        self.createdAt = ISO8601DateFormatter().string(from: createdAt)
    }

    /// Variables a body may use, with what they resolve to.
    static let variables: [(name: String, help: String)] = [
        ("firstName", "their first name"),
        ("lastName", "their last name"),
        ("name", "their full name"),
        ("slug", "their LinkedIn handle"),
        ("company", "their company (enriched)"),
        ("title", "their title (enriched)"),
        ("me", "your first name"),
    ]

    /// Fill `{firstName}` etc. Unknown placeholders stay as typed so a typo is visible.
    static func render(_ body: String, vars: [String: String]) -> String {
        var out = ""
        var rest = Substring(body)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}"), after[..<close].allSatisfy({ $0.isLetter || $0.isNumber }) {
                let key = String(after[..<close])
                out += vars[key] ?? "{\(key)}"
                rest = after[after.index(after: close)...]
            } else {
                out += "{"
                rest = after
            }
        }
        return out + rest
    }
}

@MainActor
@Observable
final class SnippetStore {
    private(set) var snippets: [Snippet] = []
    let fileURL: URL

    nonisolated static let defaultURL = StorePaths.appSupportURL.appendingPathComponent("snippets.json")

    nonisolated static var tuiURL: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("allman-tui/templates.json")
    }

    init(fileURL: URL = SnippetStore.defaultURL, seedFrom: URL? = SnippetStore.tuiURL) {
        self.fileURL = fileURL
        if let list = Self.read(fileURL) {
            snippets = list
        } else if let seed = seedFrom, let list = Self.read(seed), !list.isEmpty {
            snippets = list
            save()
        }
    }

    private static func read(_ url: URL) -> [Snippet]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Snippet].self, from: data)
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(snippets) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    @discardableResult
    func add(name: String, body: String) -> Snippet {
        let s = Snippet(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : name.trimmingCharacters(in: .whitespaces), body: body)
        snippets.append(s)
        save()
        return s
    }

    func update(_ id: String, name: String, body: String) {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[i].name = name.trimmingCharacters(in: .whitespaces)
        snippets[i].body = body
        save()
    }

    func remove(_ id: String) {
        snippets.removeAll { $0.id == id }
        save()
    }

    func move(from: IndexSet, to: Int) {
        snippets.move(fromOffsets: from, toOffset: to)
        save()
    }

    /// Import the TUI's templates (or any file in the same shape), skipping duplicates by body.
    @discardableResult
    func importFile(_ url: URL) -> Int {
        guard let list = Self.read(url) else { return 0 }
        let bodies = Set(snippets.map(\.body))
        let ids = Set(snippets.map(\.id))
        let fresh = list.filter { !bodies.contains($0.body) }.map { s -> Snippet in
            var s = s
            if ids.contains(s.id) { s.id = UUID().uuidString } // same TUI id, edited here since
            return s
        }
        snippets += fresh
        if !fresh.isEmpty { save() }
        return fresh.count
    }
}

extension ConversationRecord {
    /// Placeholder values for this contact. `connection` adds the enriched fields.
    func snippetVars(connection: Connection?, me: String?) -> [String: String] {
        let first = firstName ?? displayName.split(separator: " ").first.map(String.init) ?? ""
        return [
            "firstName": first,
            "lastName": lastName ?? "",
            "name": displayName,
            "slug": slug ?? "",
            "company": connection?.company ?? "",
            "title": connection?.title ?? "",
            "me": me?.split(separator: " ").first.map(String.init) ?? "",
        ]
    }
}

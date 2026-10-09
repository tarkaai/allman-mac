// Read-only access to `connections/` — the user's 1st-degree network as
// exported by `allman connections` (+ `enrich`). Used for compose search.

import Foundation

struct Connection: Identifiable, Hashable {
    var id: String { flagshipId }
    let flagshipId: String
    let slug: String?
    let name: String
    let headline: String?
    let title: String?
    let company: String?
    let location: String?

    var subtitle: String {
        let role = [title, company].compactMap { $0 }.joined(separator: " at ")
        return role.isEmpty ? (headline ?? "") : role
    }
}

extension StoreReader {
    private struct ConnectionFile: Decodable {
        let flagshipId: String?
        let publicIdentifier: String?
        let firstName: String?
        let lastName: String?
        let headline: String?
        let title: String?
        let company: String?
        let location: String?
    }

    func loadConnections(accountDir: URL) -> [Connection] {
        let dir = accountDir.appendingPathComponent("connections")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        let files = entries.filter { $0.pathExtension == "json" && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true }
        var out = [Connection?](repeating: nil, count: files.count)
        let lock = NSLock()
        let decoder = JSONDecoder()
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            guard let data = try? Data(contentsOf: files[i]), let c = try? decoder.decode(ConnectionFile.self, from: data) else { return }
            let name = [c.firstName, c.lastName].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let conn = Connection(flagshipId: c.flagshipId ?? files[i].deletingPathExtension().lastPathComponent, slug: c.publicIdentifier, name: name, headline: c.headline, title: c.title, company: c.company, location: c.location)
            lock.lock(); out[i] = conn; lock.unlock()
        }
        return out.compactMap { $0 }.sorted { $0.name < $1.name }
    }
}

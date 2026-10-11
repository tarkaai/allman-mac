// Read-only access to `connections/` — the user's 1st-degree network as
// exported by `allman connections` (+ `enrich`). Used for compose search and
// for the contact details shown beside a thread.

import Foundation

struct Connection: Identifiable, Hashable {
    struct Position: Codable, Hashable {
        let title: String?
        let company: String?
        let current: Bool?
        let startDate: String?
        let endDate: String?
        let location: String?
        let description: String?

        var dateRange: String? {
            guard let s = startDate else { return nil }
            return "\(Connection.yearMonth(s)) – \(endDate.map(Connection.yearMonth) ?? "Present")"
        }
    }

    struct Education: Codable, Hashable {
        let school: String?
        let degree: String?
        let fieldOfStudy: String?
        let startDate: String?
        let endDate: String?

        var summary: String { [degree, fieldOfStudy].compactMap { $0 }.joined(separator: ", ") }
    }

    var id: String { flagshipId }
    let flagshipId: String
    let slug: String?
    let name: String
    let headline: String?
    let title: String?
    let company: String?
    let location: String?
    var about: String? = nil
    var industry: String? = nil
    var pronoun: String? = nil
    var connectedAt: Date? = nil
    var enrichedAt: Date? = nil
    var enrichDepth: String? = nil
    var profilePictureUrl: String? = nil
    var positions: [Position] = []
    var education: [Education] = []
    var skills: [String] = []

    var subtitle: String {
        let role = [title, company].compactMap { $0 }.joined(separator: " at ")
        return role.isEmpty ? (headline ?? "") : role
    }

    /// "Head of GTM at Ever.green · Seattle" — the enriched replacement for a headline.
    var roleLine: String? {
        let role = [title, company].compactMap { $0 }.joined(separator: " at ")
        let parts = [role, location.map(Connection.shortLocation) ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var isEnriched: Bool { enrichedAt != nil }

    /// "SHE_HER" → "she/her".
    var pronounText: String? {
        guard let p = pronoun, !p.isEmpty else { return nil }
        return p.lowercased().split(separator: "_").joined(separator: "/")
    }

    /// "Seattle, Washington, United States" → "Seattle, Washington".
    static func shortLocation(_ s: String) -> String {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count > 2 ? parts.prefix(2).joined(separator: ", ") : s
    }

    /// "2024-09" → "Sep 2024"; "2024" stays.
    static func yearMonth(_ s: String) -> String {
        let parts = s.split(separator: "-")
        guard parts.count >= 2, let m = Int(parts[1]), (1...12).contains(m) else { return String(parts.first ?? "") }
        return "\(DateFormatter().shortMonthSymbols[m - 1]) \(parts[0])"
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
        let about: String?
        let industry: String?
        let pronoun: String?
        let connectedAt: String?
        let enrichedAt: String?
        let enrichDepth: String?
        let profilePictureUrl: String?
        let positions: [Connection.Position]?
        let education: [Connection.Education]?
        let skills: [String]?
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
            var conn = Connection(flagshipId: c.flagshipId ?? files[i].deletingPathExtension().lastPathComponent, slug: c.publicIdentifier, name: name, headline: c.headline, title: c.title, company: c.company, location: c.location)
            conn.about = c.about
            conn.industry = c.industry
            conn.pronoun = c.pronoun
            conn.connectedAt = ISO8601.date(c.connectedAt)
            conn.enrichedAt = ISO8601.date(c.enrichedAt)
            conn.enrichDepth = c.enrichDepth
            conn.profilePictureUrl = c.profilePictureUrl
            conn.positions = c.positions ?? []
            conn.education = c.education ?? []
            conn.skills = c.skills ?? []
            lock.lock(); out[i] = conn; lock.unlock()
        }
        return out.compactMap { $0 }.sorted { $0.name < $1.name }
    }
}

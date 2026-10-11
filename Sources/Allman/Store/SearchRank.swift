// Relevance for the sidebar / compose / network search boxes: prefix and
// whole-word matches outrank "these letters appear somewhere", so typing
// "AJ" puts AJ first, not everyone with an a and a j in their name.

import Foundation

enum SearchRank {
    /// Query split into lowercased tokens; every token must match somewhere.
    static func tokens(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Score one field. 0 = no match. Higher is better.
    static func score(field: String?, token: String, weight: Int) -> Int {
        guard let field, !field.isEmpty else { return 0 }
        let f = field.lowercased()
        if f == token { return 100 * weight }
        if f.hasPrefix(token) { return 80 * weight }
        let words = f.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains(token) { return 70 * weight }
        if words.contains(where: { $0.hasPrefix(token) }) { return 60 * weight }
        // Initials: "aj" → "Anthony Jones".
        if token.count >= 2, words.count >= token.count, String(words.prefix(token.count).compactMap(\.first)) == token { return 50 * weight }
        if f.contains(token) { return 20 * weight }
        return 0
    }

    /// Combined score across fields (name weighs most); 0 when any token fails to match.
    static func score(name: String, secondary: [String?], tertiary: [String?] = [], query: String) -> Int {
        let toks = tokens(query)
        guard !toks.isEmpty else { return 0 }
        var total = 0
        for t in toks {
            var best = score(field: name, token: t, weight: 3)
            for s in secondary { best = max(best, score(field: s, token: t, weight: 2)) }
            for s in tertiary { best = max(best, score(field: s, token: t, weight: 1)) }
            if best == 0 { return 0 }
            total += best
        }
        return total
    }
}

import Foundation
import SwiftUI

enum Links {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// http(s) URLs in a message body, in order.
    static func urls(in text: String) -> [URL] {
        guard let detector, !text.isEmpty else { return [] }
        let ns = text as NSString
        return detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap(\.url)
            .filter { $0.scheme == "http" || $0.scheme == "https" }
    }

    /// Body text with tappable links, styled for a light-on-blue or dark-on-gray bubble.
    static func attributed(_ text: String, onBlue: Bool) -> AttributedString {
        var out = AttributedString(text)
        guard let detector else { return out }
        let ns = text as NSString
        for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url, let range = Range(m.range, in: text) else { continue }
            let lower = AttributedString.Index(range.lowerBound, within: out)
            let upper = AttributedString.Index(range.upperBound, within: out)
            guard let lower, let upper else { continue }
            out[lower..<upper].link = url
            out[lower..<upper].underlineStyle = .single
            out[lower..<upper].foregroundColor = onBlue ? .white : Color(nsColor: .linkColor)
        }
        return out
    }
}

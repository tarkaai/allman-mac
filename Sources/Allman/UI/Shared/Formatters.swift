import Foundation

enum Fmt {
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let diff = now.timeIntervalSince(date)
        if diff < 0 { return "now" }
        let s = Int(diff)
        if s < 5 { return "now" }
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        let d = h / 24
        if d < 7 { return "\(d)d" }
        if d < 35 { return "\(d / 7)w" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: date)
    }

    static func relativeSentence(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let r = relative(date, now: now)
        if r == "now" { return "just now" }
        if r.last.map({ "smhdw".contains($0) }) == true, r.dropLast().allSatisfy(\.isNumber) { return "\(r) ago" }
        return r
    }

    static func dayLabel(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        if let week = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now)), date >= week {
            f.dateFormat = "EEEE"
        } else if cal.isDate(date, equalTo: now, toGranularity: .year) {
            f.dateFormat = "EEE, MMM d"
        } else {
            f.dateFormat = "MMM d, yyyy"
        }
        return f.string(from: date)
    }

    /// Conversation-list stamp, iMessage style: "11:23 AM" today, "Yesterday",
    /// the weekday within the last week, else a short numeric date.
    static func listTime(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return clockTime(date) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let week = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now)), date >= week {
            let f = DateFormatter(); f.dateFormat = "EEEE"; return f.string(from: date)
        }
        let f = DateFormatter(); f.dateFormat = "M/d/yy"; return f.string(from: date)
    }

    /// Thread separator, iMessage style: "Today 11:01 AM", "Yesterday 4:28 PM", "Sun, Sep 27 at 9:10 AM".
    static func threadStamp(_ date: Date, now: Date = Date()) -> (day: String, time: String) {
        let cal = Calendar.current
        let time = clockTime(date)
        if cal.isDate(date, inSameDayAs: now) { return ("Today", time) }
        if cal.isDateInYesterday(date) { return ("Yesterday", time) }
        let f = DateFormatter()
        if let week = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now)), date >= week {
            f.dateFormat = "EEEE"
        } else if cal.isDate(date, equalTo: now, toGranularity: .year) {
            f.dateFormat = "EEE, MMM d"
        } else {
            f.dateFormat = "MMM d, yyyy"
        }
        return (f.string(from: date), time)
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func clockTime(_ date: Date) -> String { clock.string(from: date) }

    static func initials(_ name: String) -> String {
        let tokens = name.split(separator: " ").map(String.init)
        let candidates = tokens.enumerated().compactMap { i, raw -> String? in
            if raw.hasSuffix(".") { return nil } // honorifics: Dr., Mr.
            let clean = raw.trimmingCharacters(in: .punctuationCharacters)
            guard let first = clean.first(where: \.isLetter) else { return nil }
            // Credentials after the name (MBA, PMP, CFA): all caps, not the first word.
            if i > 0, clean.count > 1, clean == clean.uppercased() { return nil }
            return String(first)
        }
        if candidates.isEmpty, let c = name.first { return String(c).uppercased() }
        return candidates.prefix(2).joined().uppercased()
    }
}

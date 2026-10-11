// App-owned organization of the inbox: labels (a conversation can carry
// several, and each label is its own inbox view), per-contact notes, snoozes
// and reminders, and archive. Per account, under Application Support — never
// in the store, so the CLI's git history stays clean.

import Foundation

struct InboxLabel: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    /// One of `InboxLabel.colors`.
    var color: String

    static let colors = ["red", "orange", "yellow", "green", "teal", "blue", "indigo", "purple", "pink", "gray"]

    init(id: String = UUID().uuidString, name: String, color: String) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// A snooze (hide until a time) or a reminder (keep visible, ping at a time).
struct Snooze: Codable, Hashable {
    var until: Date
    /// Newest message timestamp when set: any newer message wakes the thread.
    var sinceMessageTs: Int64
    /// Hidden from the inbox until due (snooze) vs. left in place (reminder).
    var hidden: Bool
    var note: String?
    /// The due notification has been posted.
    var fired: Bool = false
}

struct Organizer: Codable {
    var labels: [InboxLabel] = []
    /// convId -> label ids, in the order they were applied.
    var labelsByConv: [String: [String]] = [:]
    var notes: [String: String] = [:]
    var snoozes: [String: Snooze] = [:]
    /// convId -> newest message timestamp when archived; a newer message un-archives.
    var archived: [String: Int64] = [:]

    var fileURL: URL?
    private enum CodingKeys: String, CodingKey { case labels, labelsByConv, notes, snoozes, archived }

    static func fileURL(accountId: String?) -> URL {
        let safe = (accountId ?? "default").replacingOccurrences(of: "/", with: "_")
        return StorePaths.appSupportURL.appendingPathComponent("organizer-\(safe).json")
    }

    static func load(accountId: String?) -> Organizer {
        let url = fileURL(accountId: accountId)
        var o = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Organizer.self, from: $0) } ?? Organizer()
        o.fileURL = url
        return o
    }

    func save() {
        guard let url = fileURL else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Labels

    func label(_ id: String) -> InboxLabel? { labels.first { $0.id == id } }

    func labels(for convId: String) -> [InboxLabel] {
        (labelsByConv[convId] ?? []).compactMap(label)
    }

    func has(label id: String, _ convId: String) -> Bool { labelsByConv[convId]?.contains(id) ?? false }

    @discardableResult
    mutating func addLabel(name: String, color: String? = nil) -> InboxLabel {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let existing = labels.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) { return existing }
        let c = color ?? InboxLabel.colors[labels.count % InboxLabel.colors.count]
        let l = InboxLabel(name: trimmed, color: c)
        labels.append(l)
        return l
    }

    mutating func rename(label id: String, to name: String, color: String? = nil) {
        guard let i = labels.firstIndex(where: { $0.id == id }) else { return }
        labels[i].name = name.trimmingCharacters(in: .whitespaces)
        if let color { labels[i].color = color }
    }

    mutating func deleteLabel(_ id: String) {
        labels.removeAll { $0.id == id }
        for (conv, ids) in labelsByConv {
            let kept = ids.filter { $0 != id }
            if kept.isEmpty { labelsByConv[conv] = nil } else { labelsByConv[conv] = kept }
        }
    }

    mutating func toggle(label id: String, _ convId: String) {
        var ids = labelsByConv[convId] ?? []
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
        labelsByConv[convId] = ids.isEmpty ? nil : ids
    }

    func count(label id: String) -> Int { labelsByConv.values.filter { $0.contains(id) }.count }

    // MARK: Notes

    func note(_ convId: String) -> String { notes[convId] ?? "" }

    mutating func setNote(_ text: String, _ convId: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[convId] = t.isEmpty ? nil : text
    }

    // MARK: Archive

    func isArchived(_ snap: ConversationSnapshot) -> Bool {
        guard let ts = archived[snap.record.convId] else { return false }
        return (snap.lastMessage?.timestamp ?? 0) <= ts
    }

    mutating func archive(_ snap: ConversationSnapshot) {
        archived[snap.record.convId] = max(snap.lastMessage?.timestamp ?? 0, Int64(Date().timeIntervalSince1970 * 1000))
    }

    mutating func unarchive(_ convId: String) { archived[convId] = nil }

    // MARK: Snooze / reminders

    func snooze(_ convId: String) -> Snooze? { snoozes[convId] }

    /// Hidden right now: a snooze that is not yet due and has seen no newer message.
    func isSnoozed(_ snap: ConversationSnapshot, now: Date = Date()) -> Bool {
        guard let s = snoozes[snap.record.convId], s.hidden else { return false }
        if s.until <= now { return false }
        return (snap.lastMessage?.timestamp ?? 0) <= s.sinceMessageTs
    }

    /// Woken early by a newer message (the snooze no longer applies).
    func isWoken(_ snap: ConversationSnapshot) -> Bool {
        guard let s = snoozes[snap.record.convId] else { return false }
        return (snap.lastMessage?.timestamp ?? 0) > s.sinceMessageTs
    }

    func isDue(_ convId: String, now: Date = Date()) -> Bool {
        guard let s = snoozes[convId] else { return false }
        return s.until <= now
    }

    mutating func setSnooze(_ snap: ConversationSnapshot, until: Date, hidden: Bool, note: String? = nil) {
        snoozes[snap.record.convId] = Snooze(until: until, sinceMessageTs: snap.lastMessage?.timestamp ?? 0, hidden: hidden, note: note?.isEmpty == true ? nil : note)
    }

    mutating func clearSnooze(_ convId: String) { snoozes[convId] = nil }

    /// Snoozes whose time has come and which haven't pinged yet. Marks them fired.
    mutating func takeDue(now: Date = Date()) -> [String] {
        var due: [String] = []
        for (id, s) in snoozes where !s.fired && s.until <= now {
            snoozes[id]?.fired = true
            due.append(id)
        }
        return due.sorted()
    }

    /// Everything with a snooze or reminder attached, soonest first.
    var reminderIds: [String] {
        snoozes.sorted { $0.value.until < $1.value.until }.map(\.key)
    }
}

extension Snooze {
    /// Preset times, Kondo/Mail style: all land at a sensible hour, never in the past.
    static func presets(now: Date = Date()) -> [(title: String, date: Date)] {
        let cal = Calendar.current
        func at(_ hour: Int, daysAhead: Int) -> Date {
            let day = cal.date(byAdding: .day, value: daysAhead, to: cal.startOfDay(for: now))!
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        }
        var out: [(String, Date)] = []
        let inThree = now.addingTimeInterval(3 * 3600)
        out.append(("In 3 hours", inThree))
        let evening = at(18, daysAhead: 0)
        if evening > now.addingTimeInterval(3600) { out.append(("This evening", evening)) }
        out.append(("Tomorrow morning", at(9, daysAhead: 1)))
        let weekday = cal.component(.weekday, from: now) // 1 = Sunday
        let toMonday = (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7
        out.append(("Next Monday", at(9, daysAhead: toMonday)))
        out.append(("In a week", at(9, daysAhead: 7)))
        out.append(("In a month", cal.date(byAdding: .month, value: 1, to: at(9, daysAhead: 0))!))
        // Chronological, and never the same moment twice (Sunday: "Tomorrow" is "Next Monday").
        var seen = Set<Date>()
        return out.sorted { $0.1 < $1.1 }.filter { seen.insert($0.1).inserted }
    }
}

// Inbox analytics from the store: volume, who's waiting, how fast you reply —
// over a window of time (all time, a year, a month, a week, a day, or N days).
// Computed off the main thread from every thread's messages.

import Foundation

/// How far back the insights look. Calendar days: "past week" starts at the
/// beginning of the day seven days ago, not 168 hours ago.
enum InsightsRange: String, CaseIterable, Identifiable, Codable {
    case allTime, year, month, week, day, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .allTime: return "All time"
        case .year: return "Past year"
        case .month: return "Past month"
        case .week: return "Past week"
        case .day: return "Past day"
        case .custom: return "Custom"
        }
    }
    func days(custom: Int) -> Int? {
        switch self {
        case .allTime: return nil
        case .year: return 365
        case .month: return 30
        case .week: return 7
        case .day: return 1
        case .custom: return max(1, custom)
        }
    }
    /// The window's start: midnight at the beginning of the day N days ago.
    func since(now: Date = Date(), custom: Int, calendar: Calendar = .current) -> Date? {
        guard let d = days(custom: custom) else { return nil }
        return calendar.startOfDay(for: calendar.date(byAdding: .day, value: -d, to: now) ?? now)
    }
}

struct Insights: Sendable {
    struct Bucket: Identifiable, Sendable { let start: Date; let sent: Int; let received: Int; var id: Date { start } }
    struct Contact: Identifiable, Sendable { let convId: String; let name: String; let count: Int; var id: String { convId } }

    var sent = 0, received = 0
    /// Threads with an inbound message in the window, and how many of those you answered.
    var replied = 0, inboundThreads = 0
    /// Median hours from an inbound message to your next reply, within the window.
    var medianReplyHours: Double?
    var newThreads = 0
    /// Threads where they wrote last (as of now, regardless of the window).
    var needsReply = 0
    var buckets: [Bucket] = []
    /// `.day` for short windows, `.weekOfYear` otherwise.
    var bucketUnit: Calendar.Component = .weekOfYear
    var topContacts: [Contact] = []
    var totalThreads = 0
    var totalMessages = 0

    var replyRate: Double? { inboundThreads > 0 ? Double(replied) / Double(inboundThreads) : nil }

    static func compute(reader: StoreReader, accountDir: URL, snapshots: [ConversationSnapshot], since: Date?, now: Date = Date()) -> Insights {
        var ins = Insights()
        let cal = Calendar.current
        let sinceMs = since.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        // Chart buckets: days for a month or less, weeks otherwise (a year of weeks, at most, for all time).
        let spanDays = since.map { max(1, Int(now.timeIntervalSince($0) / 86_400) + 1) } ?? 365
        let daily = spanDays <= 31
        ins.bucketUnit = daily ? .day : .weekOfYear
        let count = daily ? spanDays : min(104, Int(ceil(Double(spanDays) / 7)))
        let starts: [Date] = (0..<count).reversed().compactMap { i in
            let d = cal.date(byAdding: daily ? .day : .weekOfYear, value: -i, to: now)!
            return daily ? cal.startOfDay(for: d) : cal.dateInterval(of: .weekOfYear, for: d)?.start
        }
        let chartFromMs = Int64((starts.first ?? now).timeIntervalSince1970 * 1000)
        let readFromMs = min(sinceMs, chartFromMs)
        var bucketSent = [Int](repeating: 0, count: starts.count), bucketRecv = bucketSent
        var replyGaps: [Double] = []
        var perContact: [(String, String, Int)] = []
        ins.totalThreads = snapshots.count

        let lock = NSLock()
        var partials: [(sent: Int, recv: Int, replied: Bool, inbound: Bool, newThread: Bool, needsReply: Bool, gaps: [Double], bs: [Int], br: [Int], inWindow: Int, total: Int)] = []
        let snaps = snapshots
        DispatchQueue.concurrentPerform(iterations: snaps.count) { i in
            let snap = snaps[i]
            guard let last = snap.lastMessage else { return }
            // A thread with nothing in the window only contributes its totals and "waiting on you".
            let msgs = reader.readMessages(accountDir: accountDir, convId: snap.record.convId)
            var p = (sent: 0, recv: 0, replied: false, inbound: false, newThread: false, needsReply: last.isFromMe == false, gaps: [Double](), bs: [Int](repeating: 0, count: starts.count), br: [Int](repeating: 0, count: starts.count), inWindow: 0, total: msgs.count)
            if last.timestamp >= readFromMs {
                var pendingInbound: Int64?
                for m in msgs where m.timestamp >= readFromMs {
                    if m.timestamp >= sinceMs {
                        if m.isFromMe { p.sent += 1 } else { p.recv += 1 }
                        p.inWindow += 1
                        if !m.isFromMe { if pendingInbound == nil { pendingInbound = m.timestamp } }
                        else if let t = pendingInbound { p.gaps.append(Double(m.timestamp - t) / 3_600_000); pendingInbound = nil }
                    }
                    if m.timestamp >= chartFromMs {
                        let d = Date(timeIntervalSince1970: Double(m.timestamp) / 1000)
                        if let bi = starts.lastIndex(where: { $0 <= d }) { if m.isFromMe { p.bs[bi] += 1 } else { p.br[bi] += 1 } }
                    }
                }
                if let first = msgs.first, first.timestamp >= sinceMs { p.newThread = true }
                if let lastIn = msgs.last(where: { !$0.isFromMe && $0.timestamp >= sinceMs }) {
                    p.inbound = true
                    if msgs.contains(where: { $0.isFromMe && $0.timestamp > lastIn.timestamp }) { p.replied = true }
                }
            }
            lock.lock(); partials.append(p); perContact.append((snap.record.convId, snap.record.displayName, p.inWindow)); lock.unlock()
        }
        for p in partials {
            ins.sent += p.sent; ins.received += p.recv
            if p.inbound { ins.inboundThreads += 1 }
            if p.replied { ins.replied += 1 }
            if p.newThread { ins.newThreads += 1 }
            if p.needsReply { ins.needsReply += 1 }
            replyGaps += p.gaps
            for i in starts.indices { bucketSent[i] += p.bs[i]; bucketRecv[i] += p.br[i] }
            ins.totalMessages += p.total
        }
        if !replyGaps.isEmpty {
            let sorted = replyGaps.sorted()
            ins.medianReplyHours = sorted[sorted.count / 2]
        }
        ins.buckets = starts.indices.map { Bucket(start: starts[$0], sent: bucketSent[$0], received: bucketRecv[$0]) }
        ins.topContacts = perContact.filter { $0.2 > 0 }.sorted { $0.2 > $1.2 }.prefix(8).map { Contact(convId: $0.0, name: $0.1, count: $0.2) }
        return ins
    }
}

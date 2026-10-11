// Inbox analytics from the store: volume, who's waiting, how fast you reply.
// Computed off the main thread from every thread's messages.

import Foundation

struct Insights: Sendable {
    struct Week: Identifiable, Sendable { let start: Date; let sent: Int; let received: Int; var id: Date { start } }
    struct Contact: Identifiable, Sendable { let convId: String; let name: String; let count: Int; var id: String { convId } }

    var sent7 = 0, received7 = 0, sent30 = 0, received30 = 0
    /// Inbound messages in the last 30 days that got a reply from you.
    var replied30 = 0, inboundThreads30 = 0
    /// Median hours from an inbound message to your next reply (last 90 days).
    var medianReplyHours: Double?
    var newThreads30 = 0
    var needsReply = 0
    var weeks: [Week] = []
    var topContacts: [Contact] = []
    var totalThreads = 0
    var totalMessages = 0

    var replyRate30: Double? { inboundThreads30 > 0 ? Double(replied30) / Double(inboundThreads30) : nil }

    static func compute(reader: StoreReader, accountDir: URL, snapshots: [ConversationSnapshot], now: Date = Date()) -> Insights {
        var ins = Insights()
        let cal = Calendar.current
        let ms7 = Int64(now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970 * 1000)
        let ms30 = Int64(now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970 * 1000)
        let ms90 = Int64(now.addingTimeInterval(-90 * 86_400).timeIntervalSince1970 * 1000)
        let weekStarts: [Date] = (0..<12).reversed().compactMap { i in
            let d = cal.date(byAdding: .weekOfYear, value: -i, to: now)!
            return cal.dateInterval(of: .weekOfYear, for: d)?.start
        }
        var weekSent = [Int](repeating: 0, count: weekStarts.count), weekRecv = weekSent
        let ms12w = Int64((weekStarts.first ?? now).timeIntervalSince1970 * 1000)
        var replyGaps: [Double] = []
        var perContact: [(String, String, Int)] = []
        ins.totalThreads = snapshots.count

        let lock = NSLock()
        var partials: [(sent7: Int, recv7: Int, sent30: Int, recv30: Int, replied: Bool, inbound30: Bool, newThread: Bool, needsReply: Bool, gaps: [Double], ws: [Int], wr: [Int], count30: Int, total: Int)] = []
        let snaps = snapshots
        DispatchQueue.concurrentPerform(iterations: snaps.count) { i in
            let snap = snaps[i]
            // Skip threads with no activity in the window: the tail is enough to tell.
            guard let last = snap.lastMessage, last.timestamp >= min(ms90, ms12w) else { return }
            let msgs = reader.readMessages(accountDir: accountDir, convId: snap.record.convId)
            var p = (sent7: 0, recv7: 0, sent30: 0, recv30: 0, replied: false, inbound30: false, newThread: false, needsReply: false, gaps: [Double](), ws: [Int](repeating: 0, count: weekStarts.count), wr: [Int](repeating: 0, count: weekStarts.count), count30: 0, total: msgs.count)
            var pendingInbound: Int64?
            for m in msgs {
                if m.timestamp >= ms7 { if m.isFromMe { p.sent7 += 1 } else { p.recv7 += 1 } }
                if m.timestamp >= ms30 { if m.isFromMe { p.sent30 += 1 } else { p.recv30 += 1 }; p.count30 += 1 }
                if m.timestamp >= ms12w {
                    let d = Date(timeIntervalSince1970: Double(m.timestamp) / 1000)
                    if let wi = weekStarts.lastIndex(where: { $0 <= d }) { if m.isFromMe { p.ws[wi] += 1 } else { p.wr[wi] += 1 } }
                }
                if m.timestamp >= ms90 {
                    if !m.isFromMe { if pendingInbound == nil { pendingInbound = m.timestamp } }
                    else if let t = pendingInbound { p.gaps.append(Double(m.timestamp - t) / 3_600_000); pendingInbound = nil }
                }
            }
            if let first = msgs.first, first.timestamp >= ms30 { p.newThread = true }
            let inbound30 = msgs.contains { !$0.isFromMe && $0.timestamp >= ms30 }
            if inbound30 {
                p.inbound30 = true
                if let lastIn = msgs.last(where: { !$0.isFromMe && $0.timestamp >= ms30 }), msgs.contains(where: { $0.isFromMe && $0.timestamp > lastIn.timestamp }) { p.replied = true }
            }
            p.needsReply = last.isFromMe == false
            lock.lock(); partials.append(p); perContact.append((snap.record.convId, snap.record.displayName, p.count30)); lock.unlock()
        }
        for p in partials {
            ins.sent7 += p.sent7; ins.received7 += p.recv7; ins.sent30 += p.sent30; ins.received30 += p.recv30
            if p.inbound30 { ins.inboundThreads30 += 1 }
            if p.replied { ins.replied30 += 1 }
            if p.newThread { ins.newThreads30 += 1 }
            if p.needsReply { ins.needsReply += 1 }
            replyGaps += p.gaps
            for i in weekStarts.indices { weekSent[i] += p.ws[i]; weekRecv[i] += p.wr[i] }
            ins.totalMessages += p.total
        }
        if !replyGaps.isEmpty {
            let sorted = replyGaps.sorted()
            ins.medianReplyHours = sorted[sorted.count / 2]
        }
        ins.weeks = weekStarts.indices.map { Week(start: weekStarts[$0], sent: weekSent[$0], received: weekRecv[$0]) }
        ins.topContacts = perContact.filter { $0.2 > 0 }.sorted { $0.2 > $1.2 }.prefix(8).map { Contact(convId: $0.0, name: $0.1, count: $0.2) }
        return ins
    }
}

// CSV / Markdown exports of what's on disk plus the app's labels and notes —
// the hand-off to a spreadsheet or CRM without any integration.

import Foundation

enum Exporter {
    static func csvField(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        let needsQuotes = s.contains(",") || s.contains("\"") || s.contains("\n")
        let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
        return needsQuotes ? "\"\(escaped)\"" : escaped
    }

    /// One row per conversation: who, where, labels, note, last activity.
    static func conversationsCSV(_ snapshots: [ConversationSnapshot], organizer: Organizer, connection: (ConversationRecord) -> Connection?) -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["name,first_name,last_name,slug,profile_url,headline,title,company,location,degree,labels,note,last_message_at,last_message_from,last_message,needs_reply,archived,snoozed_until,thread_url"]
        for snap in snapshots {
            let r = snap.record
            let c = connection(r)
            let last = snap.lastMessage
            let row: [String?] = [
                r.displayName, r.firstName, r.lastName, r.slug, r.linkedInProfileURL?.absoluteString, r.headline,
                c?.title, c?.company, c?.location, r.distance.map { $0.replacingOccurrences(of: "DISTANCE_", with: "") },
                organizer.labels(for: r.convId).map(\.name).joined(separator: "; "),
                organizer.note(r.convId),
                last.map { iso.string(from: $0.date) },
                last.map { $0.isFromMe ? "me" : "them" },
                last?.previewText,
                last.map { $0.isFromMe ? "no" : "yes" },
                organizer.isArchived(snap) ? "yes" : "no",
                organizer.snooze(r.convId).map { iso.string(from: $0.until) },
                r.linkedInThreadURL?.absoluteString,
            ]
            lines.append(row.map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A thread as Markdown: header with contact details, then dated messages.
    static func threadMarkdown(_ snap: ConversationSnapshot, messages: [Message], organizer: Organizer, connection: Connection?, me: String) -> String {
        let r = snap.record
        var out = "# \(r.displayName)\n\n"
        if let h = connection?.roleLine ?? r.headline { out += "_\(h)_  \n" }
        if let u = r.linkedInProfileURL { out += "\(u.absoluteString)  \n" }
        let labels = organizer.labels(for: r.convId).map(\.name)
        if !labels.isEmpty { out += "Labels: \(labels.joined(separator: ", "))  \n" }
        let note = organizer.note(r.convId)
        if !note.isEmpty { out += "\n> **Note:** \(note.replacingOccurrences(of: "\n", with: "\n> "))\n" }
        out += "\n---\n\n"
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        for m in messages {
            let who = m.isFromMe ? me : (m.fromName ?? r.displayName)
            out += "**\(who)** · \(f.string(from: m.date))\n\n"
            if let s = m.subject, !s.isEmpty { out += "_\(s)_\n\n" }
            if !m.body.isEmpty { out += m.body + "\n\n" }
            for a in m.attachments where a.type != "replied" { out += "- \(a.summary)\(a.linkURL.map { " <\($0.absoluteString)>" } ?? "")\n" }
            if let q = m.attachments.first(where: { $0.type == "replied" }) { out += "> replying to \(q.authorName ?? ""): \(q.originalText ?? "")\n" }
            if !m.reactions.isEmpty { out += "_\(m.reactions.map { "\($0.emoji)\($0.count > 1 ? " \($0.count)" : "")" }.joined(separator: " "))_\n" }
            out += "\n"
        }
        return out
    }
}

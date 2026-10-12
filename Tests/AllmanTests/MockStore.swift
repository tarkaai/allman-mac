import Foundation

/// A synthetic `~/.allman`-shaped store for tests: one account, thirty 1:1 threads
/// (some unread, one long), and one group thread (Priya Example + Theo Sample) in the
/// shape allman-cli ≥ 0.6 writes. Nothing here touches LinkedIn or the real store.
enum MockStore {
    static let profileId = "ACoAAMOCK0000000000000000000000000"
    static let slug = "mocky"
    static let groupConvId = "2-MOCKGROUP0000000000000000000000000000000000000000000=="
    static let group3ConvId = "2-MOCKGROUP3000000000000000000000000000000000000000000=="

    @discardableResult
    static func make(at root: URL) throws -> URL {
        let fm = FileManager.default
        let account = root.appendingPathComponent(profileId)
        try fm.createDirectory(at: account.appendingPathComponent("connections"), withIntermediateDirectories: true)
        let auth: [String: Any?] = [
            "urn": "urn:li:fsd_profile:\(profileId)", "profileSlug": slug, "name": "Mock User", "headline": "Testing things",
            "profileUrl": nil, "imageUrl": nil, "userType": nil, "networkSize": 12, "status": "authenticated", "lastSyncAt": iso(Date()),
        ]
        try write(json: auth, to: account.appendingPathComponent("AUTH.json"))
        try fm.createSymbolicLink(at: root.appendingPathComponent(slug), withDestinationURL: URL(fileURLWithPath: profileId))

        let now = Date()
        let names = ["Avery Lane", "Blake Rivera", "Cam Nguyen", "Dakota Shaw", "Emerson Cole", "Finley Park", "Harper Quinn", "Indigo Reyes", "Jordan Blake", "Kai Morgan",
                     "Logan Pierce", "Morgan Ellis", "Noa Fischer", "Oakley Brooks", "Parker Lane", "Quinn Harper", "Reese Dalton", "Sage Winters", "Tatum Reed", "Uma Patel",
                     "Val Santos", "Wren Tucker", "Xan Lowell", "Yael Stern", "Zion Carter", "Aria Chen", "Bodhi Malik", "Cleo Vance", "Dash Holloway", "Ember Ruiz"]
        for (i, name) in names.enumerated() {
            let convId = "2-MOCK\(String(format: "%02d", i))" + String(repeating: "0", count: 44) + "=="
            let pid = "ACoAAMOCKPERSON\(String(format: "%02d", i))"
            let parts = name.split(separator: " ").map(String.init)
            let pslug = name.lowercased().replacingOccurrences(of: " ", with: "-")
            let unread = i % 4 == 1
            let last = now.addingTimeInterval(-Double(i) * 3600 * 5)
            let count = i == 0 ? 60 : 3 + (i % 5)
            var msgs: [[String: Any?]] = []
            for m in 0..<count {
                let ts = Int64(last.timeIntervalSince1970 * 1000) - Int64((count - m) * 6 * 60 * 1000)
                let mine = (m + i) % 3 == 0
                msgs.append(message(urn: "urn:li:messagingMessage:2-m\(i)-\(m)", ts: ts, fromUrn: mine ? "urn:li:fsd_profile:\(profileId)" : "urn:li:fsd_profile:\(pid)", fromName: mine ? "Mock User" : name, mine: mine, body: mine ? "Mine \(m): following up on the plan." : "\(parts[0]) says \(m): sounds good, let's do it."))
            }
            // Thread 2 ends with their message you reacted to (a reply, for "Needs my reply"); thread 3 ends with theirs, unanswered.
            if i == 2 || i == 3 {
                var m = message(urn: "urn:li:messagingMessage:2-m\(i)-last", ts: Int64(last.timeIntervalSince1970 * 1000) - 1000, fromUrn: "urn:li:fsd_profile:\(pid)", fromName: name, mine: false, body: "\(parts[0]) asks: does Thursday work?")
                if i == 2 { m["reactions"] = [["emoji": "👍", "count": 1, "hasUserReacted": true]] }
                msgs.append(m)
            }
            try writeConversation(account: account, convId: convId, record: record(convId: convId, pid: pid, slug: pslug, first: parts[0], last: parts[1], name: name, headline: "Role \(i) at Company \(i)", unread: unread, lastActivity: last, created: last.addingTimeInterval(-86400 * 30), total: count), messages: msgs)
            try fm.createSymbolicLink(at: account.appendingPathComponent(pslug), withDestinationURL: URL(fileURLWithPath: convId))
            try fm.createSymbolicLink(at: account.appendingPathComponent(pid), withDestinationURL: URL(fileURLWithPath: convId))
        }

        // The group: participants in the CLI's contract shape; no slug/profile aliases.
        let priya = participant(pid: "ACoAAMOCKPRIYA", slug: "priya-example", first: "Priya", last: "Example", headline: "Engineer at Example Co")
        let theo = participant(pid: "ACoAAMOCKTHEO", slug: "theo-sample", first: "Theo", last: "Sample", headline: "Founder at Sample Labs")
        var rec = record(convId: groupConvId, pid: "ACoAAMOCKPRIYA", slug: nil, first: "Priya", last: "Example", name: "Priya Example, Theo Sample", headline: "Engineer at Example Co", unread: true, lastActivity: now.addingTimeInterval(-600), created: now.addingTimeInterval(-7200), total: 5)
        rec["isGroup"] = true
        rec["title"] = nil
        rec["participants"] = [priya, theo]
        let base = Int64(now.timeIntervalSince1970 * 1000) - 7_000_000
        let gmsgs: [[String: Any?]] = [
            message(urn: "urn:li:messagingMessage:2-g0", ts: base, fromUrn: "urn:li:fsd_profile:\(profileId)", fromName: "Mock User", mine: true, body: "Group test — hi both"),
            message(urn: "urn:li:messagingMessage:2-g1", ts: base + 60_000, fromUrn: "urn:li:fsd_profile:ACoAAMOCKPRIYA", fromName: "Priya Example", mine: false, body: "Hey! Got it."),
            message(urn: "urn:li:messagingMessage:2-g2", ts: base + 120_000, fromUrn: "urn:li:fsd_profile:ACoAAMOCKPRIYA", fromName: "Priya Example", mine: false, body: "Works for me."),
            message(urn: "urn:li:messagingMessage:2-g3", ts: base + 180_000, fromUrn: "urn:li:fsd_profile:ACoAAMOCKTHEO", fromName: "Theo Sample", mine: false, body: "Same here, thanks."),
            message(urn: "urn:li:messagingMessage:2-g4", ts: base + 240_000, fromUrn: "urn:li:fsd_profile:\(profileId)", fromName: "Mock User", mine: true, body: "Great, talk soon."),
        ]
        try writeConversation(account: account, convId: groupConvId, record: rec, messages: gmsgs)

        // A three-person group, older than the pair.
        let ro = participant(pid: "ACoAAMOCKRO", slug: "ro-example", first: "Ro", last: "Example", headline: "Designer at Example Co")
        var rec3 = record(convId: group3ConvId, pid: "ACoAAMOCKPRIYA", slug: nil, first: "Priya", last: "Example", name: "Priya Example, Theo Sample, Ro Example", headline: "Engineer at Example Co", unread: false, lastActivity: now.addingTimeInterval(-3 * 86400), created: now.addingTimeInterval(-10 * 86400), total: 2)
        rec3["isGroup"] = true; rec3["title"] = nil; rec3["participants"] = [priya, theo, ro]
        let b3 = Int64(now.addingTimeInterval(-3 * 86400).timeIntervalSince1970 * 1000)
        try writeConversation(account: account, convId: group3ConvId, record: rec3, messages: [
            message(urn: "urn:li:messagingMessage:2-h0", ts: b3, fromUrn: "urn:li:fsd_profile:ACoAAMOCKRO", fromName: "Ro Example", mine: false, body: "Three of us here."),
            message(urn: "urn:li:messagingMessage:2-h1", ts: b3 + 60_000, fromUrn: "urn:li:fsd_profile:\(profileId)", fromName: "Mock User", mine: true, body: "Noted!"),
        ])
        return root
    }

    // MARK: Shapes

    static func record(convId: String, pid: String, slug: String?, first: String, last: String, name: String, headline: String, unread: Bool, lastActivity: Date, created: Date, total: Int) -> [String: Any?] {
        [
            "convId": convId, "profileId": pid, "slug": slug,
            "convUrn": "urn:li:msg_conversation:(urn:li:fsd_profile:\(profileId),\(convId))",
            "backendUrn": "urn:li:messagingThread:\(convId)", "profileUrn": "urn:li:fsd_profile:\(pid)", "memberUrn": nil,
            "firstName": first, "lastName": last, "name": name, "headline": headline,
            "profileUrl": "https://www.linkedin.com/in/\(pid)", "profilePictures": nil,
            "distance": "DISTANCE_1", "pronoun": nil, "memberBadgeType": nil, "isPremium": false, "isVerified": false,
            "unreadCount": unread ? 1 : 0, "lastActivityAt": iso(lastActivity), "lastReadAt": unread ? nil : iso(lastActivity),
            "createdAt": iso(created), "read": !unread, "notificationStatus": "ACTIVE", "categories": ["INBOX", "PRIMARY_INBOX"],
            "conversationUrl": "https://www.linkedin.com/messaging/thread/\(convId)/", "disabledFeatures": [],
            "syncState": ["oldestMessageAt": Int64(created.timeIntervalSince1970 * 1000), "newestMessageAt": Int64(lastActivity.timeIntervalSince1970 * 1000), "lastSyncAt": iso(lastActivity), "totalSynced": total, "fullyBackfilled": true],
            "fetchedAt": iso(lastActivity),
        ]
    }

    static func participant(pid: String, slug: String, first: String, last: String, headline: String) -> [String: Any?] {
        ["profileId": pid, "profileUrn": "urn:li:fsd_profile:\(pid)", "backendUrn": "urn:li:msg_messagingParticipant:urn:li:fsd_profile:\(pid)", "slug": slug,
         "firstName": first, "lastName": last, "name": "\(first) \(last)", "headline": headline, "profileUrl": "https://www.linkedin.com/in/\(slug)",
         "profilePictures": nil, "distance": "DISTANCE_1", "pronoun": nil, "memberBadgeType": nil, "isPremium": false, "isVerified": false]
    }

    static func message(urn: String, ts: Int64, fromUrn: String, fromName: String, mine: Bool, body: String) -> [String: Any?] {
        ["urn": urn, "timestamp": ts, "fromUrn": fromUrn, "fromName": fromName, "isFromMe": mine, "body": body, "reactions": [], "attachments": [], "originToken": nil]
    }

    static func writeConversation(account: URL, convId: String, record: [String: Any?], messages: [[String: Any?]]) throws {
        let dir = account.appendingPathComponent(convId)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("messages"), withIntermediateDirectories: true)
        try write(json: record, to: dir.appendingPathComponent("RECORD.json"))
        let lines = try messages.map { try String(decoding: JSONSerialization.data(withJSONObject: $0.mapValues { $0 ?? NSNull() }), as: UTF8.self) }
        let month = DateFormatter(); month.dateFormat = "yyyy-MM"
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("messages/\(month.string(from: Date())).jsonl"), atomically: true, encoding: .utf8)
    }

    static func write(json: [String: Any?], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json.mapValues { $0 ?? NSNull() }, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}

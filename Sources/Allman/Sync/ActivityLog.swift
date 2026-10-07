// A short, human-readable trail of what the sync engine has been doing —
// the "report of recently syncing stuff" shown in the menu bar panel.

import Foundation

struct ActivityItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case message, sent, sync, live, network, auth, warning, error

        var symbol: String {
            switch self {
            case .message: return "bubble.left.fill"
            case .sent: return "paperplane.fill"
            case .sync: return "arrow.triangle.2.circlepath"
            case .live: return "bolt.fill"
            case .network: return "wifi"
            case .auth: return "person.crop.circle.badge.exclamationmark"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }
    }

    let id = UUID()
    let date: Date
    let kind: Kind
    let title: String
    let detail: String?
    let convId: String?

    init(_ kind: Kind, _ title: String, detail: String? = nil, convId: String? = nil, date: Date = Date()) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.convId = convId
        self.date = date
    }
}

struct ActivityLog {
    private(set) var items: [ActivityItem] = []
    let capacity: Int

    init(capacity: Int = 60) { self.capacity = capacity }

    mutating func add(_ item: ActivityItem) {
        items.insert(item, at: 0)
        if items.count > capacity { items.removeLast(items.count - capacity) }
    }

    /// Collapse repeated identical titles (e.g. "Reconnecting…" every 30s) into the newest.
    mutating func addCoalescing(_ item: ActivityItem) {
        if let first = items.first, first.kind == item.kind, first.title == item.title, first.detail == item.detail {
            items[0] = item
            return
        }
        add(item)
    }
}

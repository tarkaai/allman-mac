import SwiftUI

struct ConversationListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var inbox = model.inbox
        let rows = inbox.filtered
        Group {
            if rows.isEmpty && !inbox.isLoading {
                ContentUnavailableView {
                    Label(emptyTitle(inbox), systemImage: inbox.filter == .unread ? "checkmark.circle" : "magnifyingglass")
                } description: {
                    Text(inbox.searchText.isEmpty ? "Nothing matches this filter." : "Try another name, headline, or phrase.")
                }
            } else {
                List(rows, selection: Binding(get: { inbox.selectedConvId }, set: { inbox.select($0) })) { snap in
                    ConversationRow(snapshot: snap, unreadCount: inbox.unreadCount(snap))
                        .tag(snap.record.convId)
                        .contextMenu {
                            if inbox.isUnread(snap) { Button("Mark as Read") { inbox.markSeen(snap.record.convId) } }
                            if let url = snap.record.linkedInProfileURL { Button("Open LinkedIn Profile") { NSWorkspace.shared.open(url) } }
                            if let url = snap.record.linkedInThreadURL { Button("Open Thread on LinkedIn") { NSWorkspace.shared.open(url) } }
                        }
                }
                .listStyle(.sidebar)
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                StatusBadge(status: model.engine.status, syncing: model.engine.isSyncing)
                Spacer()
                Text(countText(inbox))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 6)
        }
        .searchable(text: $inbox.searchText, placement: .sidebar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker("Filter", selection: $inbox.filter) {
                        ForEach(InboxModel.Filter.allCases) { f in
                            Label(f == .unread && inbox.unreadCount > 0 ? "Unread (\(inbox.unreadCount))" : f.rawValue, systemImage: f.symbol).tag(f)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                    Button("Mark All as Read") { inbox.markAllSeen() }.disabled(inbox.unreadCount == 0)
                } label: {
                    Label("Filter", systemImage: inbox.filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .help(inbox.filter == .all ? "Filter conversations" : "Filtering: \(inbox.filter.rawValue)")
            }
        }
    }

    private func emptyTitle(_ inbox: InboxModel) -> String {
        if !inbox.searchText.isEmpty { return "No matches" }
        switch inbox.filter {
        case .unread: return "All caught up"
        case .needsReply: return "Nothing waiting on you"
        case .awaitingReply: return "No open threads"
        default: return "No conversations"
        }
    }

    private func countText(_ inbox: InboxModel) -> String {
        if inbox.filter != .all || !inbox.searchText.isEmpty {
            return "\(inbox.filtered.count) of \(inbox.snapshots.count)"
        }
        return inbox.unreadCount > 0 ? "\(inbox.unreadCount) unread · \(inbox.snapshots.count)" : "\(inbox.snapshots.count) conversations"
    }
}

struct ConversationRow: View {
    let snapshot: ConversationSnapshot
    let unreadCount: Int

    var body: some View {
        let r = snapshot.record
        let unread = unreadCount > 0
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: r.avatarURL, name: r.displayName, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(r.displayName)
                        .font(.body.weight(unread ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Fmt.listTime(snapshot.activityDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(alignment: .top, spacing: 6) {
                    if let m = snapshot.lastMessage {
                        Text((m.isFromMe ? "You: " : "") + m.previewText.replacingOccurrences(of: "\n", with: " "))
                            .font(.callout)
                            .foregroundStyle(unread ? .primary : .secondary)
                            .lineLimit(2)
                    } else if let h = r.headline {
                        Text(h).font(.callout).foregroundStyle(.tertiary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if unread {
                        Text("\(unreadCount)")
                            .font(.caption2.weight(.bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, unreadCount > 9 ? 6 : 0)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Color(nsColor: .systemBlue), in: Capsule())
                            .padding(.top, 1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

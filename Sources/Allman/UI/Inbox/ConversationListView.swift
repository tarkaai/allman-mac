import SwiftUI

struct ConversationListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var inbox = model.inbox
        let rows = inbox.filtered
        Group {
            if rows.isEmpty && !inbox.isLoading {
                ContentUnavailableView {
                    Label(inbox.filter == .unread && inbox.searchText.isEmpty ? "All caught up" : "No matches", systemImage: inbox.filter == .unread ? "checkmark.circle" : "magnifyingglass")
                } description: {
                    Text(inbox.filter == .unread && inbox.searchText.isEmpty ? "No unread conversations." : "Try another name, headline, or phrase.")
                }
            } else {
                List(rows, selection: Binding(get: { inbox.selectedConvId }, set: { inbox.select($0) })) { snap in
                    ConversationRow(snapshot: snap, unread: inbox.isUnread(snap))
                        .tag(snap.record.convId)
                        .contextMenu {
                            if inbox.isUnread(snap) { Button("Mark as Read") { inbox.markSeen(snap.record.convId) } }
                            if let url = snap.record.linkedInProfileURL { Button("Open LinkedIn Profile") { NSWorkspace.shared.open(url) } }
                            if let url = snap.record.linkedInThreadURL { Button("Open Thread on LinkedIn") { NSWorkspace.shared.open(url) } }
                        }
                }
                .listStyle(.sidebar)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    HStack {
                        Text("\(inbox.snapshots.count) conversations")
                        if inbox.unreadCount > 0 { Text("· \(inbox.unreadCount) unread") }
                        Spacer()
                        if inbox.isLoading { ProgressView().controlSize(.mini) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.bar)
                }
            }
        }
        .searchable(text: $inbox.searchText, placement: .sidebar, prompt: "Search people and messages")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation { inbox.filter = inbox.filter == .unread ? .all : .unread }
                } label: {
                    Label(inbox.filter == .unread ? "Showing unread" : "Show unread only",
                          systemImage: inbox.filter == .unread ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .help(inbox.filter == .unread ? "Showing unread only (⇧⌘U)" : "Show unread only (⇧⌘U)")
                .badge(inbox.filter == .unread ? 0 : inbox.unreadCount)
            }
        }
    }
}

struct ConversationRow: View {
    let snapshot: ConversationSnapshot
    let unread: Bool

    var body: some View {
        let r = snapshot.record
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: r.avatarURL, name: r.displayName, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(r.displayName)
                        .font(.body.weight(unread ? .semibold : .regular))
                        .lineLimit(1)
                    if r.isVerified == true { Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.blue) }
                    Spacer(minLength: 6)
                    Text(Fmt.relative(snapshot.activityDate))
                        .font(.caption)
                        .foregroundStyle(unread ? Color.accentColor : .secondary)
                        .monospacedDigit()
                }
                if let m = snapshot.lastMessage {
                    Text((m.isFromMe ? "You: " : "") + m.previewText.replacingOccurrences(of: "\n", with: " "))
                        .font(.callout)
                        .foregroundStyle(unread ? .primary : .secondary)
                        .lineLimit(2)
                } else if let h = r.headline {
                    Text(h).font(.callout).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            if unread {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8).padding(.top, 6)
            }
        }
        .padding(.vertical, 4)
    }
}

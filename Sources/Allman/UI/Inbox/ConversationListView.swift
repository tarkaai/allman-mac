import SwiftUI

struct ConversationListView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var inbox = model.inbox
        let rows = inbox.filtered
        let showPins = !inbox.pinnedSnapshots.isEmpty && inbox.searchText.trimmingCharacters(in: .whitespaces).isEmpty && inbox.filter == .all
        Group {
            if rows.isEmpty && !inbox.isLoading && !showPins {
                ContentUnavailableView {
                    Label(emptyTitle(inbox), systemImage: inbox.filter == .unread ? "checkmark.circle" : "magnifyingglass")
                } description: {
                    Text(inbox.searchText.isEmpty ? "Nothing matches this filter." : "Try another name, headline, or phrase.")
                }
            } else {
                List(selection: Binding(get: { inbox.selectedConvId }, set: { inbox.select($0) })) {
                    if showPins {
                        PinnedGrid()
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
                            .listRowSeparator(.hidden)
                            .selectionDisabled()
                    }
                    ForEach(rows) { snap in
                        ConversationRow(snapshot: snap, unreadCount: inbox.unreadCount(snap))
                            .tag(snap.record.convId)
                            .contextMenu { rowMenu(snap) }
                    }
                }
                .listStyle(.sidebar)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .focused($listFocused)
                .onKeyPress(.return) { inbox.requestFocus(.composer); return .handled }
                .onKeyPress(.space) { inbox.requestFocus(.composer); return .handled }
            }
        }
        .searchable(text: $inbox.searchText, placement: .sidebar, prompt: "Search")
        .searchFocused($searchFocused)
        .toolbar(removing: .sidebarToggle)
        .onChange(of: inbox.focusToken) { _, _ in
            switch inbox.focusTarget {
            case .list: listFocused = true
            case .search: searchFocused = true
            case .composer: break // the composer observes this itself
            }
        }
        .onAppear { listFocused = true }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    if let session = model.current {
                        AccountMenu {
                            AvatarView(url: session.avatarURL, name: session.displayName, size: 22)
                                .overlay(alignment: .bottomTrailing) {
                                    if model.sessions.count > 1 {
                                        Image(systemName: "chevron.down.circle.fill")
                                            .font(.system(size: 9)).symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .secondary)
                                            .offset(x: 2, y: 2)
                                    }
                                }
                        }
                    }
                    StatusBadge(status: model.engine.status, syncing: model.engine.isSyncing, compact: true)
                        .help(model.engine.status.label)
                    Text(countText(inbox))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).fixedSize()
                        .help("Conversations in the store")
                }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .automatic) {
                Button { NotificationCenter.default.post(name: .allmanCompose, object: nil) } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                .help("New message (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
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

    @ViewBuilder
    private func rowMenu(_ snap: ConversationSnapshot) -> some View {
        let inbox = model.inbox
        let id = snap.record.convId
        if inbox.isPinned(id) {
            Button("Unpin") { inbox.togglePin(id) }
        } else {
            Button("Pin") { inbox.togglePin(id) }.disabled(!inbox.canPinMore)
        }
        if inbox.isUnread(snap) { Button("Mark as Read") { inbox.markSeen(id) } }
        Divider()
        if let url = snap.record.linkedInProfileURL { Button("Open LinkedIn Profile") { NSWorkspace.shared.open(url) } }
        if let url = snap.record.linkedInThreadURL { Button("Open Thread on LinkedIn") { NSWorkspace.shared.open(url) } }
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
            // Don't count the pinned selection as a match.
            let pinned = inbox.selectedConvId.flatMap { id in inbox.filtered.first { $0.record.convId == id } }
            let matches = inbox.filtered.count - (pinned != nil && inbox.filter == .unread && !inbox.isUnread(pinned!) ? 1 : 0)
            return "\(matches) of \(inbox.snapshots.count)"
        }
        return inbox.unreadCount > 0 ? "\(inbox.unreadCount) unread · \(inbox.snapshots.count)" : "\(inbox.snapshots.count)"
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
                        .foregroundStyle(.primary)
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


/// Messages-style favorites: big avatars at the top of the sidebar.
struct PinnedGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let inbox = model.inbox
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 10) {
            ForEach(inbox.pinnedSnapshots) { snap in
                let id = snap.record.convId
                let unread = inbox.unreadCount(snap)
                let selected = inbox.selectedConvId == id
                Button { inbox.select(id) } label: {
                    VStack(spacing: 4) {
                        AvatarView(url: snap.record.avatarURL, name: snap.record.displayName, size: 56)
                            .overlay(Circle().stroke(selected ? Color.accentColor : .clear, lineWidth: 2.5).padding(-3))
                            .overlay(alignment: .topTrailing) {
                                if unread > 0 {
                                    Text("\(unread)")
                                        .font(.caption2.weight(.bold)).monospacedDigit()
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, unread > 9 ? 5 : 0)
                                        .frame(minWidth: 18, minHeight: 18)
                                        .background(Color(nsColor: .systemBlue), in: Capsule())
                                        .overlay(Capsule().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                                        .offset(x: 4, y: -2)
                                }
                            }
                        Text(snap.record.firstName?.isEmpty == false ? snap.record.firstName! : snap.record.displayName)
                            .font(.caption)
                            .fontWeight(unread > 0 ? .semibold : .regular)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(snap.record.displayName)
                .contextMenu {
                    Button("Unpin") { inbox.togglePin(id) }
                    if inbox.isUnread(snap) { Button("Mark as Read") { inbox.markSeen(id) } }
                    if let url = snap.record.linkedInProfileURL { Button("Open LinkedIn Profile") { NSWorkspace.shared.open(url) } }
                }
                .draggable(id)
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.first, dragged != id, let to = inbox.pinnedSnapshots.firstIndex(where: { $0.record.convId == id }) else { return false }
                    inbox.movePin(dragged, to: to)
                    return true
                }
            }
        }
    }
}

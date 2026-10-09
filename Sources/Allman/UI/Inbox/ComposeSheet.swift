import SwiftUI

/// "New Message": find someone in your conversations, your connections, on
/// LinkedIn (via `allman people`), or paste a profile URL — then start a draft.
struct ComposeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var remote: [PersonHit] = []
    @State private var searching = false
    @State private var remoteError: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        let inbox = model.inbox
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Name, or a linkedin.com/in/… link", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { pickFirst() }
                if searching { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            List {
                if let slug = pastedSlug {
                    Section("Profile link") {
                        row(name: "linkedin.com/in/\(slug)", subtitle: "Start a conversation with this profile", symbol: "link") {
                            start(DraftRecipient(slug: slug, name: slug, headline: nil, avatarURL: nil))
                        }
                    }
                }
                let convs = matchingConversations
                if !convs.isEmpty {
                    Section("Conversations") {
                        ForEach(convs) { snap in
                            personRow(name: snap.record.displayName, subtitle: snap.record.headline ?? snap.record.slug.map { "@\($0)" } ?? "", avatar: snap.record.avatarURL) {
                                inbox.draft = nil
                                inbox.select(snap.record.convId)
                                dismiss()
                            }
                        }
                    }
                }
                let conns = matchingConnections
                if !conns.isEmpty {
                    Section("Connections") {
                        ForEach(conns) { c in
                            personRow(name: c.name, subtitle: c.subtitle, avatar: nil) {
                                if let slug = c.slug { start(DraftRecipient(slug: slug, name: c.name, headline: c.subtitle, avatarURL: nil)) }
                            }
                            .disabled(c.slug == nil)
                        }
                    }
                }
                if !remote.isEmpty || remoteError != nil {
                    Section("LinkedIn") {
                        ForEach(remote) { hit in
                            personRow(name: hit.name, subtitle: [hit.headline, hit.location].compactMap { $0 }.joined(separator: " · "), avatar: hit.avatarURL, badge: hit.distanceLabel) {
                                if let slug = hit.slug { start(DraftRecipient(slug: slug, name: hit.name, headline: hit.headline, avatarURL: hit.avatarURL)) }
                            }
                            .disabled(hit.slug == nil)
                        }
                        if let remoteError {
                            Label(remoteError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    Text("Type a name to search your conversations and connections. LinkedIn search kicks in after three characters.")
                        .font(.callout).foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 520, height: 520)
        .onAppear {
            focused = true
            inbox.loadConnectionsIfNeeded()
        }
        .onChange(of: query) { _, q in scheduleRemoteSearch(q) }
    }

    // MARK: Matching

    private var normalizedQuery: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var pastedSlug: String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let r = q.range(of: #"linkedin\.com/in/([^/?\s]+)"#, options: .regularExpression) {
            let m = q[r]
            return String(m.split(separator: "/").last ?? "")
        }
        // A bare slug: no spaces, has a dash or digits, longer than 4 chars.
        if !q.contains(" "), q.count > 4, q.contains(where: { $0 == "-" || $0.isNumber }), q.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
            return q.lowercased()
        }
        return nil
    }

    private var matchingConversations: [ConversationSnapshot] {
        let q = normalizedQuery
        guard q.count >= 2 else { return [] }
        return Array(model.inbox.snapshots.filter {
            $0.record.displayName.lowercased().contains(q) || ($0.record.slug?.lowercased().contains(q) ?? false)
        }.prefix(6))
    }

    private var matchingConnections: [Connection] {
        let q = normalizedQuery
        guard q.count >= 2 else { return [] }
        let convSlugs = Set(matchingConversations.compactMap { $0.record.slug })
        return Array(model.inbox.connections.filter {
            !convSlugs.contains($0.slug ?? "") &&
            ($0.name.lowercased().contains(q) || ($0.slug?.lowercased().contains(q) ?? false) || ($0.company?.lowercased().contains(q) ?? false))
        }.prefix(12))
    }

    private func scheduleRemoteSearch(_ q: String) {
        searchTask?.cancel()
        remoteError = nil
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, pastedSlug == nil else { remote = []; searching = false; return }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do {
                let hits = try await model.inbox.searchPeople(trimmed)
                guard !Task.isCancelled else { return }
                remote = hits
            } catch let err as AllmanError where err.stderr.contains("unknown command") {
                remoteError = "LinkedIn search needs a newer allman CLI."
            } catch {
                guard !Task.isCancelled else { return }
                remoteError = (error as? AllmanError)?.friendlyMessage ?? error.localizedDescription
            }
        }
    }

    private func pickFirst() {
        if let slug = pastedSlug { start(DraftRecipient(slug: slug, name: slug, headline: nil, avatarURL: nil)); return }
        if let c = matchingConversations.first { model.inbox.draft = nil; model.inbox.select(c.record.convId); dismiss(); return }
        if let c = matchingConnections.first, let slug = c.slug { start(DraftRecipient(slug: slug, name: c.name, headline: c.subtitle, avatarURL: nil)); return }
        if let h = remote.first, let slug = h.slug { start(DraftRecipient(slug: slug, name: h.name, headline: h.headline, avatarURL: h.avatarURL)) }
    }

    private func start(_ recipient: DraftRecipient) {
        model.inbox.startDraft(recipient)
        dismiss()
    }

    // MARK: Rows

    private func personRow(name: String, subtitle: String, avatar: URL?, badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AvatarView(url: avatar, name: name, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(name).font(.body)
                        if let badge { Text(badge).font(.caption2.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                    }
                    if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(name: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 32, height: 32).background(.quaternary, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.body)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Someone you're about to message who has no local conversation yet.
struct DraftRecipient: Hashable {
    let slug: String
    let name: String
    let headline: String?
    let avatarURL: URL?
    var convId: String { "draft:\(slug)" }
}

/// A person from `allman people --json` (LinkedIn search through the CLI).
struct PersonHit: Decodable, Identifiable, Hashable {
    var id: String { profileId ?? slug ?? name }
    let name: String
    let slug: String?
    let profileId: String?
    let headline: String?
    let location: String?
    let distance: String?
    let imageUrl: String?

    var avatarURL: URL? { imageUrl.flatMap { URL(string: $0) } }
    var distanceLabel: String? {
        switch distance {
        case "DISTANCE_1": return "1st"
        case "DISTANCE_2": return "2nd"
        case "DISTANCE_3": return "3rd"
        default: return nil
        }
    }
}

/// Empty thread for a draft recipient, with the composer ready.
struct DraftThreadView: View {
    @Environment(AppModel.self) private var model
    let recipient: DraftRecipient

    var body: some View {
        VStack(spacing: 0) {
            ContentUnavailableView {
                Label("New message to \(recipient.name)", systemImage: "square.and.pencil")
            } description: {
                Text("Sent through allman. If you already have a thread on LinkedIn, it will pick that up.")
            }
            .frame(maxHeight: .infinity)
            ComposerView(convId: recipient.convId, firstName: recipient.name.split(separator: " ").first.map(String.init) ?? recipient.name)
        }
        .navigationTitle(recipient.name)
        .navigationSubtitle(recipient.headline ?? "linkedin.com/in/\(recipient.slug)")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                AvatarView(url: recipient.avatarURL, name: recipient.name, size: 26).padding(.trailing, 2)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                Button { model.inbox.draft = nil } label: { Label("Discard draft", systemImage: "xmark") }
            }
        }
    }
}

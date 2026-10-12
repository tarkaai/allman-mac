import AppKit
import SwiftUI

/// Network sidebar: sections, search, and what the jobs are doing.
struct NetworkSidebar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var net = model.network
        let inbox = model.inbox
        VStack(spacing: 0) {
            SearchField(text: $net.query, focused: $searchFocused, prompt: "Name, title, company, location")
                .padding(.horizontal, 12).padding(.bottom, 6)
            List(selection: $net.tab) {
                Label {
                    HStack { Text("Connections"); Spacer(); Text(inbox.connections.count.formatted()).foregroundStyle(.secondary).monospacedDigit() }
                } icon: { Image(systemName: "person.2") }
                .tag(NetworkModel.Tab.connections)
                Label {
                    HStack { Text("Invitations sent"); Spacer(); Text("\(net.invitations.count)").foregroundStyle(.secondary).monospacedDigit() }
                } icon: { Image(systemName: "person.badge.plus") }
                .tag(NetworkModel.Tab.invitations)
                Section("Profile details") {
                    let enriched = inbox.connections.filter(\.isEnriched).count
                    Label {
                        HStack { Text("Enriched"); Spacer(); Text(enriched.formatted()).foregroundStyle(.secondary).monospacedDigit() }
                    } icon: { Image(systemName: NetworkModel.Tab.enriched.symbol) }
                    .tag(NetworkModel.Tab.enriched)
                    Label {
                        HStack { Text("Missing"); Spacer(); Text((inbox.connections.count - enriched).formatted()).foregroundStyle(.secondary).monospacedDigit() }
                    } icon: { Image(systemName: NetworkModel.Tab.missing.symbol) }
                    .tag(NetworkModel.Tab.missing)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .contentMargins(.top, 0, for: .scrollContent)
            if let job = net.job {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(job.kind.rawValue) · \(job.progress)").font(AFont.meta).lineLimit(2)
                    Spacer()
                    Button("Stop") { net.cancel() }.controlSize(.mini)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            } else if let err = net.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(AFont.meta).foregroundStyle(.orange).lineLimit(3).padding(.horizontal, 12).padding(.vertical, 8)
            } else if let r = net.lastResult {
                Label(r, systemImage: "checkmark.circle.fill").font(AFont.meta).foregroundStyle(.green).lineLimit(2).padding(.horizontal, 12).padding(.vertical, 8)
            } else if AllmanBinary.resolve()?.lastPathComponent == "fake-allman.sh" {
                Label("Fake CLI (harness): network jobs are simulated.", systemImage: "testtube.2").font(AFont.meta).foregroundStyle(.orange).padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .onAppear { inbox.loadConnectionsIfNeeded() }
    }
}

/// Your 1st-degree network as stored by the CLI, with the CLI's network jobs.
struct NetworkDetail: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\Connection.name)]
    @State private var connecting = false
    @State private var enrichLimit = 50
    @State private var enrichDeep = false
    @State private var confirmPull = false

    var body: some View {
        let inbox = model.inbox
        let net = model.network
        Group {
            if net.tab.isConnectionsList { connectionsTable(inbox) } else { invitationsTable(net) }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaBar(edge: .top) {
            PageBar {
                PageHeader(symbol: net.tab.symbol, title: net.tab.rawValue, line1: subtitle(inbox, net), line2: net.query.isEmpty ? nil : "\(filtered.count.formatted()) match “\(net.query)”")
            } trailing: {
                HStack(spacing: 8) {
                    Button { confirmPull = true } label: { Label("Pull Connections", systemImage: "arrow.down.circle") }
                        .disabled(net.isBusy)
                        .help("allman connections: refresh your 1st-degree list from LinkedIn (paced, idempotent)")
                    Menu {
                        Picker("Up to", selection: $enrichLimit) {
                            ForEach([10, 25, 50, 100, 250], id: \.self) { Text("\($0) profiles").tag($0) }
                        }
                        Toggle("Deep (history, education, skills)", isOn: $enrichDeep)
                        Divider()
                        Button("Start") { net.enrichMissing(limit: enrichLimit, deep: enrichDeep) }
                    } label: { Label("Enrich", systemImage: "person.text.rectangle") }
                        .disabled(net.isBusy)
                        .help("allman enrich: title, company, location and about for connections that lack them (quota-capped by the CLI)")
                    Button { connecting = true } label: { Label("Connect…", systemImage: "person.badge.plus") }
                        .disabled(net.isBusy)
                        .help("Send a connection request (allman connect)")
                }
                .controlSize(.small)
            }
        }
        .sheet(isPresented: $connecting) { ConnectSheet(slug: "", name: "").environment(model) }
        .alert("Pull connections from LinkedIn?", isPresented: $confirmPull) {
            Button("Pull all") { net.pullConnections() }
            Button("First 500") { net.pullConnections(limit: 500) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Walks your 1st-degree list 100 at a time with a short pause between pages. Existing records are updated in place.")
        }
    }

    private func subtitle(_ inbox: InboxModel, _ net: NetworkModel) -> String {
        if net.tab == .invitations { return "Connection requests recorded by allman connect" }
        let all = inbox.connections
        guard !all.isEmpty else { return "No connections stored yet" }
        let enriched = all.filter(\.isEnriched).count
        switch net.tab {
        case .enriched: return "\(enriched.formatted()) of \(all.count.formatted()) connections have title, company, location and about"
        case .missing: return "\((all.count - enriched).formatted()) connections still need allman enrich"
        default: return "\(all.count.formatted()) connections · \(enriched.formatted()) with profile details"
        }
    }

    /// The tab's subset of the store, then the search.
    private var scoped: [Connection] {
        let all = model.inbox.connections
        switch model.network.tab {
        case .enriched: return all.filter(\.isEnriched)
        case .missing: return all.filter { !$0.isEnriched }
        default: return all
        }
    }

    private var filtered: [Connection] {
        let q = model.network.query.trimmingCharacters(in: .whitespaces)
        let all = scoped
        guard !q.isEmpty else { return all.sorted(using: sortOrder) }
        var scores: [String: Int] = [:]
        let rows = all.filter { c in
            let sc = SearchRank.score(name: c.name, secondary: [c.title, c.company, c.slug], tertiary: [c.location, c.headline], query: q)
            if sc > 0 { scores[c.id] = sc }
            return sc > 0
        }
        return rows.sorted { (scores[$0.id] ?? 0, $0.name) > (scores[$1.id] ?? 0, $1.name) }
    }

    @ViewBuilder
    private func connectionsTable(_ inbox: InboxModel) -> some View {
        let rows = filtered
        if inbox.connections.isEmpty {
            ContentUnavailableView {
                Label("No connections stored", systemImage: "person.2")
            } description: {
                Text("Pull your 1st-degree list from LinkedIn to search it here and find people to message.")
            } actions: {
                Button("Pull Connections") { confirmPull = true }.disabled(model.network.isBusy)
            }
        } else {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { c in
                    HStack(spacing: 8) {
                        AvatarView(url: c.profilePictureUrl.flatMap(URL.init(string:)), name: c.name, size: 22)
                        Text(c.name).lineLimit(1)
                        if let slug = c.slug, inbox.snapshots.contains(where: { $0.record.slug == slug }) {
                            Image(systemName: "bubble.left.fill").font(.caption2).foregroundStyle(.secondary).help("You have a thread")
                        }
                    }
                }
                .width(min: 140, ideal: 200)
                TableColumn("Title", value: \.title.orEmpty) { c in Text(c.title ?? c.headline ?? "").foregroundStyle(c.title == nil ? .secondary : .primary).lineLimit(1) }
                    .width(min: 80)
                TableColumn("Company", value: \.company.orEmpty) { Text($0.company ?? "").lineLimit(1) }
                    .width(min: 80)
                TableColumn("Location", value: \.location.orEmpty) { Text($0.location.map(Connection.shortLocation) ?? "").lineLimit(1) }
                    .width(min: 80)
                TableColumn("Connected", value: \.connectedAt.orDistantPast) { c in Text(c.connectedAt.map(Fmt.monthDayYear) ?? "").foregroundStyle(.secondary).lineLimit(1) }
                    .width(min: 84, ideal: 96, max: 110)
                TableColumn("", value: \.enrichedAt.orDistantPast) { c in
                    Image(systemName: c.isEnriched ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(c.isEnriched ? Color.green : Color.secondary)
                        .help(c.isEnriched ? "Enriched \(c.enrichedAt.map(Fmt.monthDayYear) ?? "") (\(c.enrichDepth ?? "core"))" : "Not enriched")
                }
                .width(28)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let picked = ids.compactMap { id in inbox.connections.first { $0.id == id } }
                if picked.count == 1, let c = picked.first {
                    Button("Message \(c.name.split(separator: " ").first.map(String.init) ?? c.name)") { message(c) }.disabled(c.slug == nil)
                    if let slug = c.slug { Button("Open LinkedIn Profile") { NSWorkspace.shared.open(URL(string: "https://www.linkedin.com/in/\(slug)/")!) } }
                    Divider()
                    if let slug = c.slug {
                        Button(c.isEnriched ? "Refresh Profile Details" : "Fetch Profile Details") { inbox.enrich(slug: slug, force: c.isEnriched) }.disabled(inbox.enriching.contains(slug))
                        Button("Copy Profile Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("https://www.linkedin.com/in/\(slug)/", forType: .string) }
                    }
                } else if !picked.isEmpty {
                    Text("\(picked.count) selected")
                    Button("Copy Names") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(picked.map(\.name).joined(separator: "\n"), forType: .string) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let c = inbox.connections.first(where: { $0.id == id }) { message(c) }
            }
        }
    }

    private func message(_ c: Connection) {
        guard let slug = c.slug else { return }
        if let existing = model.inbox.snapshots.first(where: { $0.record.slug == slug }) {
            model.openInbox(convId: existing.record.convId)
        } else {
            model.inbox.startDraft(DraftRecipient(slug: slug, name: c.name, headline: c.subtitle, avatarURL: c.profilePictureUrl.flatMap(URL.init(string:))))
            model.openInbox(convId: nil)
            model.experience = .messenger
        }
    }

    @ViewBuilder
    private func invitationsTable(_ net: NetworkModel) -> some View {
        if net.invitations.isEmpty {
            ContentUnavailableView("No invitations sent from allman", systemImage: "person.badge.plus", description: Text("Connection requests you send here or with allman connect are recorded so nobody is invited twice."))
        } else {
            Table(net.invitations) {
                TableColumn("Person") { inv in Text(inv.slug.map { "@\($0)" } ?? inv.inviteeId) }
                TableColumn("Sent") { inv in Text(inv.sentAt.map(Fmt.monthDayYear) ?? "").foregroundStyle(.secondary) }.width(min: 90, max: 120)
                TableColumn("Note") { inv in Text(inv.note ?? "—").foregroundStyle(inv.note == nil ? .tertiary : .primary).lineLimit(1) }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let inv = net.invitations.first(where: { $0.id == id }), let slug = inv.slug {
                    Button("Open LinkedIn Profile") { NSWorkspace.shared.open(URL(string: "https://www.linkedin.com/in/\(slug)/")!) }
                }
            }
        }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
private extension Optional where Wrapped == Date {
    var orDistantPast: Date { self ?? .distantPast }
}

/// Send a connection request through `allman connect`, with the CLI's rules spelled out.
struct ConnectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var slug: String
    @State var name: String
    @State private var note = ""
    @State private var sending = false
    @State private var error: String?
    @State private var confirming = false

    static let maxNote = 300

    private var cleanSlug: String {
        let q = slug.trimmingCharacters(in: .whitespaces)
        if let r = q.range(of: #"linkedin\.com/in/([^/?\s]+)"#, options: .regularExpression) { return String(q[r].split(separator: "/").last ?? "") }
        return q.replacingOccurrences(of: "@", with: "")
    }

    var body: some View {
        let net = model.network
        let already = model.inbox.connectionsBySlug[cleanSlug] != nil
        let invited = net.invited(slug: cleanSlug)
        VStack(alignment: .leading, spacing: 12) {
            Text(name.isEmpty ? "Send a connection request" : "Connect with \(name)").font(.headline)
            TextField("linkedin.com/in/… or handle", text: $slug).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $note)
                    .font(.body)
                    .frame(height: 90)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                    .overlay(alignment: .topLeading) { if note.isEmpty { Text("Optional note").foregroundStyle(.tertiary).padding(8).allowsHitTesting(false) } }
                HStack {
                    Text("\(note.count)/\(Self.maxNote)").font(.caption).foregroundStyle(note.count > Self.maxNote ? .red : .secondary).monospacedDigit()
                    Spacer()
                    Text("Free accounts get very few invitations with a note per month; without a note is safer.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if already {
                Label("Already a 1st-degree connection in your store.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
            } else if let invited {
                Label("Already invited\(invited.sentAt.map { " on \(Fmt.monthDayYear($0))" } ?? "").", systemImage: "clock").font(.callout).foregroundStyle(.orange)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            Text("This sends a real, irreversible LinkedIn invitation through allman connect. The CLI spaces invitations a minute apart and stops at its daily cap.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(sending ? "Sending…" : "Send Request") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || cleanSlug.isEmpty || note.count > Self.maxNote || already || invited != nil || net.isBusy)
            }
        }
        .padding(16)
        .frame(width: 460)
        .confirmationDialog("Send a connection request to @\(cleanSlug)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Send") { send() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(note.isEmpty ? "No note." : "With your note.") }
    }

    private func send() {
        sending = true
        error = nil
        model.network.connect(slug: cleanSlug, note: note) { result in
            sending = false
            switch result {
            case .success: dismiss()
            case .failure(let e): error = (e as? AllmanError)?.friendlyMessage ?? e.localizedDescription
            }
        }
    }
}

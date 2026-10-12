import AppKit
import SwiftUI

/// The inspector beside a thread: who this person is (from the connections
/// store when `allman enrich` has run), plus the app's own context for them.
struct ContactInspector: View {
    @Environment(AppModel.self) private var model
    let snapshot: ConversationSnapshot
    @State private var aboutExpanded = false

    var body: some View {
        let inbox = model.inbox
        let r = snapshot.record
        let conn = inbox.connection(for: r)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(r, conn)
                organize(r.convId)
                if let conn, conn.isEnriched {
                    enrichedDetails(conn)
                } else {
                    notEnriched(r, conn)
                }
                links(r)
            }
            .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    // MARK: Sections

    private func header(_ r: ConversationRecord, _ conn: Connection?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(url: r.avatarURL ?? conn?.profilePictureUrl.flatMap(URL.init(string:)), name: r.displayName, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.displayName).font(AFont.title).lineLimit(2)
                    HStack(spacing: 6) {
                        if let p = conn?.pronounText ?? pronoun(r.pronoun) { Text(p).font(AFont.meta).foregroundStyle(.secondary) }
                        if let d = distance(r.distance) { badge(d) }
                        if r.isPremium == true { badge("Premium") }
                        if r.isVerified == true { Image(systemName: "checkmark.seal.fill").font(AFont.meta).foregroundStyle(.blue).help("Verified") }
                    }
                }
            }
            if let h = r.headline ?? conn?.headline, !h.isEmpty {
                Text(h).font(AFont.secondary).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            }
            if let loc = conn?.location, !loc.isEmpty { Label(loc, systemImage: "mappin.and.ellipse").font(AFont.meta).foregroundStyle(.secondary) }
            if let ind = conn?.industry { Label(ind, systemImage: "building.2").font(AFont.meta).foregroundStyle(.secondary) }
            if let c = conn?.connectedAt { Label("Connected \(Fmt.monthDayYear(c))", systemImage: "person.2").font(AFont.meta).foregroundStyle(.secondary) }
        }
    }

    /// The app's own context: labels, note, snooze/reminder.
    private func organize(_ convId: String) -> some View {
        let inbox = model.inbox
        let labels = inbox.organizer.labels(for: convId)
        return VStack(alignment: .leading, spacing: 14) {
            section("Labels") {
                HStack(spacing: 4) {
                    FlowLayout(spacing: 4) {
                        ForEach(labels) { l in
                            LabelChip(label: l).contextMenu {
                                Button("Remove") { inbox.toggle(label: l.id, convId) }
                                Divider()
                                LabelMenu(label: l)
                            }
                        }
                        Button { inbox.showLabelPicker = true } label: {
                            Image(systemName: "plus").font(AFont.metaStrong).frame(width: 20, height: 20).background(Color.primary.opacity(0.06), in: Circle())
                        }
                        .buttonStyle(.plain).help("Add label (L)")
                    }
                }
            }
            section("Note") { NoteEditor(convId: convId) }
            if let s = inbox.organizer.snooze(convId) {
                section(s.hidden ? "Snoozed" : "Reminder") {
                    HStack(spacing: 6) {
                        Image(systemName: s.until <= Date() ? "bell.badge.fill" : "clock").foregroundStyle(.orange)
                        Text(Fmt.reminderTime(s.until)).font(AFont.secondary)
                        Spacer()
                        Button("Clear") { inbox.clearSnooze(convId) }.buttonStyle(.link).font(AFont.meta)
                    }
                    if let n = s.note, !n.isEmpty { Text(n).font(AFont.meta).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func enrichedDetails(_ conn: Connection) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let about = conn.about, !about.isEmpty {
                section("About") {
                    Text(about).font(AFont.secondary).lineLimit(aboutExpanded ? nil : 6).textSelection(.enabled)
                    if about.count > 280 {
                        Button(aboutExpanded ? "Show less" : "Show more") { withAnimation { aboutExpanded.toggle() } }
                            .buttonStyle(.link).font(AFont.meta)
                    }
                }
            }
            if !conn.positions.isEmpty {
                section("Experience") {
                    ForEach(Array(conn.positions.prefix(6).enumerated()), id: \.offset) { _, p in
                        VStack(alignment: .leading, spacing: 1) {
                            Text([p.title, p.company].compactMap { $0 }.joined(separator: " · ")).font(p.current == true ? AFont.bodyMedium : AFont.body)
                            if let d = p.dateRange { Text(d).font(AFont.meta).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if !conn.education.isEmpty {
                section("Education") {
                    ForEach(Array(conn.education.prefix(3).enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.school ?? "").font(AFont.secondary)
                            if !e.summary.isEmpty { Text(e.summary).font(AFont.meta).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if !conn.skills.isEmpty {
                section("Skills") {
                    Text(conn.skills.prefix(12).joined(separator: " · ")).font(AFont.meta).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("From LinkedIn · \(conn.enrichedAt.map { Fmt.monthDayYear($0) } ?? "")").font(AFont.micro).foregroundStyle(.tertiary)
                Spacer()
                if let slug = conn.slug {
                    Button(model.inbox.enriching.contains(slug) ? "Refreshing…" : "Refresh") { model.inbox.enrich(slug: slug, force: true) }
                        .buttonStyle(.link).font(AFont.micro)
                        .disabled(model.inbox.enriching.contains(slug))
                }
            }
        }
    }

    private func notEnriched(_ r: ConversationRecord, _ conn: Connection?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(conn == nil ? "Not in your stored connections." : "Only the headline is stored for this contact.")
                .font(AFont.meta).foregroundStyle(.secondary)
            if let slug = r.slug {
                let busy = model.inbox.enriching.contains(slug)
                Button {
                    model.inbox.enrich(slug: slug)
                } label: {
                    Label(busy ? "Fetching…" : "Fetch profile details", systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
                .disabled(busy)
                .help("allman enrich \(slug) --deep: title, company, location, about and history (counts toward the CLI's enrichment quota)")
            }
        }
    }

    private func links(_ r: ConversationRecord) -> some View {
        let inbox = model.inbox
        let busy = inbox.backfilling.contains(r.convId)
        return VStack(alignment: .leading, spacing: 6) {
            if r.syncState?.fullyBackfilled == true {
                HStack(spacing: 6) {
                    Label("History complete", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    Button("Refresh") { inbox.refreshRecent(r.convId, force: true) }.buttonStyle(.link)
                }
            } else {
                Button { inbox.backfill(r.convId) } label: {
                    Label(busy ? "Loading older history…" : "Load full history", systemImage: busy ? "clock.arrow.circlepath" : "clock.arrow.circlepath")
                }
                .buttonStyle(.link)
                .disabled(busy)
                .help("Walk this thread back to its first message (allman sync <conv>)")
            }
            if let url = r.linkedInProfileURL {
                Button { NSWorkspace.shared.open(url) } label: { Label("LinkedIn profile", systemImage: "person.crop.rectangle") }.buttonStyle(.link)
            }
            if let url = r.linkedInThreadURL {
                Button { NSWorkspace.shared.open(url) } label: { Label("Thread on linkedin.com", systemImage: "arrow.up.right.square") }.buttonStyle(.link)
            }
            if let slug = r.slug {
                Text("@\(slug)").font(AFont.meta.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            }
        }
        .font(AFont.secondary)
    }

    // MARK: Bits

    @ViewBuilder
    func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(AFont.microStrong).foregroundStyle(.secondary).kerning(0.5)
            content()
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(AFont.microStrong).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
    }

    private func distance(_ d: String?) -> String? {
        switch d {
        case "DISTANCE_1": return "1st"
        case "DISTANCE_2": return "2nd"
        case "DISTANCE_3": return "3rd"
        default: return nil
        }
    }

    private func pronoun(_ p: String?) -> String? {
        guard let p, !p.isEmpty else { return nil }
        return p.lowercased().split(separator: "_").joined(separator: "/")
    }
}


/// Wraps chips onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

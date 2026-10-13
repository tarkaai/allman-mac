import Charts
import SwiftUI

/// Insights sidebar: which account the numbers are for (every signed-in account is listed).
struct InsightsSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.insightsAccountId ?? model.current?.id }, set: { model.insightsAccountId = $0 })) {
            Section("Accounts") {
                ForEach(model.sessions) { s in
                    HStack(spacing: 8) {
                        AvatarView(url: s.avatarURL, name: s.displayName, size: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.displayName).font(AFont.body).lineLimit(1)
                            Text("@\(s.slug)").font(AFont.meta).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(s.id)
                    .uiProbe("insights-account-\(s.id)")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

/// Inbox analytics for one account over a window of time.
struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @State private var insights: Insights?
    @State private var customDraft = ""
    @State private var computing = false

    var body: some View {
        @Bindable var model = model
        let session = model.insightsSession
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            // The window of time, by calendar days.
            HStack(spacing: 6) {
                FlowLayout(spacing: 4) {
                    ForEach(InsightsRange.allCases) { r in
                        let on = model.insightsRange == r
                        Button { model.insightsRange = r; reload() } label: {
                            Text(r.title)
                                .font(on ? AFont.chipStrong : AFont.chip)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(on ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                                .foregroundStyle(on ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                        .iconHover()
                        .help(r == .allTime ? "Every stored message" : (r == .custom ? "A number of calendar days of your choosing" : "Since the start of the day \(r.days(custom: 0) ?? 0) days ago"))
                        .uiProbe("insights-range-\(r.rawValue)")
                    }
                    if computing { ProgressView().controlSize(.mini).padding(.leading, 4).help("Recomputing") }
                    if model.insightsRange == .custom {
                        HStack(spacing: 4) {
                            TextField("days", text: $customDraft)
                                .textFieldStyle(.roundedBorder).frame(width: 56)
                                .onSubmit { applyCustom() }
                                .help("How many calendar days back")
                            Text("days").font(AFont.meta).foregroundStyle(.secondary)
                        }
                        .uiProbe("insights-custom-days")
                    }
                }
            }
            if let ins = insights {
                let label = rangeLabel
                HStack(spacing: 10) {
                    tile("Sent · \(label)", "\(ins.sent)", "messages you wrote").uiProbe("insights-tile-sent")
                    tile("Received · \(label)", "\(ins.received)", "messages they wrote")
                    tile("Reply rate", ins.replyRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", "\(ins.replied) of \(ins.inboundThreads) threads answered")
                    tile("Median reply time", ins.medianReplyHours.map(Self.hours) ?? "—", label)
                }
                HStack(spacing: 10) {
                    tile("Waiting on you", "\(ins.needsReply)", "threads where they wrote last")
                    tile("New threads · \(label)", "\(ins.newThreads)", "conversations that started")
                    tile("Stored", "\(ins.totalThreads.formatted())", "\(ins.totalMessages.formatted()) messages, all time")
                }
                Text(ins.bucketUnit == .day ? "Messages per day" : "Messages per week").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Chart {
                    ForEach(ins.buckets) { b in
                        BarMark(x: .value("When", b.start, unit: ins.bucketUnit), y: .value("Count", b.received))
                            .foregroundStyle(by: .value("Direction", "Received"))
                        BarMark(x: .value("When", b.start, unit: ins.bucketUnit), y: .value("Count", b.sent))
                            .foregroundStyle(by: .value("Direction", "Sent"))
                    }
                }
                .chartForegroundStyleScale(["Received": Color(nsColor: .systemGray), "Sent": Color(nsColor: .systemBlue)])
                .frame(height: 150)
                if !ins.topContacts.isEmpty {
                    Text("Most active · \(label)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    VStack(spacing: 2) {
                        ForEach(ins.topContacts) { c in
                            Button {
                                if let s = session { model.select(accountId: s.id) }
                                model.experience = .messenger
                                model.inbox.select(c.convId, reveal: true)
                            } label: {
                                HStack {
                                    Text(c.name).font(.callout)
                                    Spacer()
                                    Text("\(c.count) message\(c.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .iconHover()
                            .help("Open this conversation")
                        }
                    }
                }
            } else {
                HStack { Spacer(); ProgressView("Reading every thread…"); Spacer() }.frame(height: 200)
            }
        }
        .padding(18)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaBar(edge: .top) {
            PageBar {
                // Two lines: the page, and whose numbers these are.
                PageHeader(symbol: "chart.bar.xaxis", title: "Insights", line1: session.map { "\($0.displayName) · @\($0.slug)" })
                    .uiProbe("insights-header")
            } trailing: {
                IconButton(symbol: "arrow.clockwise", help: "Recompute from the store", size: .band) { reload() }
            }
        }
        .task(id: "\(session?.id ?? "-")|\(model.insightsRange.rawValue)|\(model.insightsCustomDays)") { await load() }
        .onAppear { customDraft = String(model.insightsCustomDays) }
    }

    private var rangeLabel: String {
        switch model.insightsRange {
        case .allTime: return "all time"
        case .custom: return "\(model.insightsCustomDays)d"
        default: return "\(model.insightsRange.days(custom: 0) ?? 0)d"
        }
    }

    private func applyCustom() {
        if let n = Int(customDraft.trimmingCharacters(in: .whitespaces)), n > 0 { model.insightsCustomDays = n; reload() }
    }

    /// The numbers stay on screen while the next window computes; each value then animates to its new figure.
    private func reload() { Task { await load() } }

    private func load() async {
        guard let session = model.insightsSession else { return }
        if session.inbox.snapshots.isEmpty { await session.inbox.reloadAll() }
        guard let dir = session.inbox.accountDir else { return }
        let reader = model.reader
        let snaps = session.inbox.snapshots
        let since = model.insightsRange.since(custom: model.insightsCustomDays)
        computing = true
        let next = await Task.detached(priority: .userInitiated) { Insights.compute(reader: reader, accountDir: dir, snapshots: snaps, since: since) }.value
        computing = false
        withAnimation(.easeInOut(duration: 0.3)) { insights = next }
    }

    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
            Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    static func hours(_ h: Double) -> String {
        if h < 1 { return "\(Int((h * 60).rounded()))m" }
        if h < 48 { return String(format: "%.1fh", h) }
        return "\(Int((h / 24).rounded()))d"
    }
}

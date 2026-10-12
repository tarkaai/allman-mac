import Charts
import SwiftUI

/// Inbox analytics: volume by week, reply rate and speed, who's waiting.
/// Insights sidebar: what the numbers cover.
struct InsightsSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: .constant("overview")) {
            Label("Overview", systemImage: "chart.bar.xaxis").tag("overview")
            Section("Covers") {
                Text("Every stored thread for @\(model.current?.slug ?? "—"): the last 7 and 30 days for volume, 90 days for reply speed, 12 weeks on the chart.")
                    .font(AFont.meta).foregroundStyle(.secondary)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.sidebar)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @State private var insights: Insights?

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            if let ins = insights {
                HStack(spacing: 10) {
                    tile("Sent · 7d", "\(ins.sent7)", "\(ins.sent30) in 30d")
                    tile("Received · 7d", "\(ins.received7)", "\(ins.received30) in 30d")
                    tile("Reply rate · 30d", ins.replyRate30.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", "\(ins.replied30) of \(ins.inboundThreads30) threads")
                    tile("Median reply time", ins.medianReplyHours.map(Self.hours) ?? "—", "last 90 days")
                }
                HStack(spacing: 10) {
                    tile("Waiting on you", "\(ins.needsReply)", "threads where they wrote last")
                    tile("New threads · 30d", "\(ins.newThreads30)", "conversations that started")
                    tile("Stored", "\(ins.totalThreads.formatted())", "\(ins.totalMessages.formatted()) messages")
                }
                Text("Messages per week").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Chart {
                    ForEach(ins.weeks) { w in
                        BarMark(x: .value("Week", w.start, unit: .weekOfYear), y: .value("Count", w.received))
                            .foregroundStyle(by: .value("Direction", "Received"))
                        BarMark(x: .value("Week", w.start, unit: .weekOfYear), y: .value("Count", w.sent))
                            .foregroundStyle(by: .value("Direction", "Sent"))
                    }
                }
                .chartForegroundStyleScale(["Received": Color(nsColor: .systemGray), "Sent": Color(nsColor: .systemBlue)])
                .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                .frame(height: 150)
                if !ins.topContacts.isEmpty {
                    Text("Most active · 30d").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    VStack(spacing: 2) {
                        ForEach(ins.topContacts) { c in
                            Button {
                                model.experience = .messenger
                                model.inbox.select(c.convId)
                            } label: {
                                HStack {
                                    Text(c.name).font(.callout)
                                    Spacer()
                                    Text("\(c.count) message\(c.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                PageHeader(symbol: "chart.bar.xaxis", title: "Insights", line1: model.current.map { "\($0.displayName) · @\($0.slug)" }, line2: insights.map { "\($0.totalThreads.formatted()) threads · \($0.totalMessages.formatted()) messages" })
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                Button { insights = nil; Task { await load() } } label: { Label("Recompute", systemImage: "arrow.clockwise") }.help("Recompute")
            }
        }
        .task(id: model.currentId) { await load() }
    }

    private func load() async {
        guard let dir = model.inbox.accountDir else { return }
        let reader = model.reader
        let snaps = model.inbox.snapshots
        insights = await Task.detached(priority: .userInitiated) { Insights.compute(reader: reader, accountDir: dir, snapshots: snaps) }.value
    }

    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
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

import AppKit
import SwiftUI

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    let snapshot: ConversationSnapshot

    private struct DayGroup: Identifiable {
        let id: Date
        let label: String
        let messages: [Message]
    }

    var body: some View {
        let inbox = model.inbox
        let convId = snapshot.record.convId
        let messages = inbox.messages[convId] ?? []
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if inbox.backfilling.contains(convId) {
                            HStack { Spacer(); ProgressView().controlSize(.small); Text("Loading older history…").font(.caption).foregroundStyle(.secondary); Spacer() }
                                .padding(.vertical, 6)
                        }
                        ForEach(groups(messages)) { group in
                            DayDivider(label: group.label)
                            ForEach(group.messages) { msg in
                                MessageBubble(message: msg, contactName: snapshot.record.displayName) { emoji in
                                    Task { await inbox.react(msg, in: convId, emoji: emoji) }
                                }
                                .id(msg.id)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .overlay {
                    if messages.isEmpty && inbox.loadingThread.contains(convId) { ProgressView() }
                    else if messages.isEmpty && !inbox.backfilling.contains(convId) {
                        ContentUnavailableView("No messages stored yet", systemImage: "text.bubble", description: Text("Say hello below, or load the history from LinkedIn."))
                    }
                }
            }
            ComposerView(convId: convId, firstName: snapshot.record.firstName ?? snapshot.record.displayName)
        }
        .navigationTitle(snapshot.record.displayName)
        .navigationSubtitle(snapshot.record.headline ?? snapshot.record.slug.map { "@\($0)" } ?? "")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                AvatarView(url: snapshot.record.avatarURL, name: snapshot.record.displayName, size: 26)
                    .padding(.trailing, 2)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if snapshot.record.syncState?.fullyBackfilled != true {
                    Button { inbox.backfill(convId) } label: { Label("Load full history", systemImage: "clock.arrow.circlepath") }
                        .disabled(inbox.backfilling.contains(convId))
                        .help("Walk this thread back to its first message")
                }
                if let url = snapshot.record.linkedInProfileURL {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Profile", systemImage: "person.crop.rectangle") }
                        .help("Open LinkedIn profile")
                }
                if let url = snapshot.record.linkedInThreadURL {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open on LinkedIn", systemImage: "arrow.up.right.square") }
                        .help("Open this thread on linkedin.com (⇧⌘O)")
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func groups(_ messages: [Message]) -> [DayGroup] {
        let cal = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [Message]] = [:]
        for m in messages {
            let day = cal.startOfDay(for: m.date)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(m)
        }
        return order.sorted().map { DayGroup(id: $0, label: Fmt.dayLabel($0), messages: buckets[$0] ?? []) }
    }
}

struct DayDivider: View {
    let label: String
    var body: some View {
        HStack {
            Rectangle().fill(.quaternary).frame(height: 1)
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .padding(.vertical, 8)
    }
}

struct MessageBubble: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let contactName: String
    let onReact: (String) -> Void

    static let quickReactions = ["👍", "❤️", "😂", "🎉", "👏", "🙏"]
    @State private var hovering = false

    var body: some View {
        let mine = message.isFromMe
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 80) } else { timeGutter }
            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                if let subject = message.subject, !subject.isEmpty {
                    Text(subject).font(.callout.weight(.semibold))
                }
                if !message.body.isEmpty {
                    Text(message.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: 560, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, a in
                    AttachmentChip(attachment: a)
                }
                if !message.reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(message.reactions, id: \.emoji) { r in
                            Button { onReact(r.emoji) } label: {
                                Text(r.count > 1 ? "\(r.emoji) \(r.count)" : r.emoji)
                                    .font(.caption)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(r.hasUserReacted ? Color.accentColor.opacity(0.25) : Color(nsColor: .quaternaryLabelColor).opacity(0.35), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(r.hasUserReacted ? "Remove your reaction" : "React with \(r.emoji)")
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background {
                if mine { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.accentColor.opacity(0.22)) }
                else { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.fill.tertiary) }
            }
            .contextMenu {
                ForEach(Self.quickReactions, id: \.self) { e in Button(e) { onReact(e) } }
                Divider()
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.body, forType: .string)
                }
                .disabled(message.body.isEmpty)
            }
            if mine { timeGutter } else { Spacer(minLength: 80) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityLabel("\(mine ? "You" : contactName), \(Fmt.clockTime(message.date)): \(message.previewText)")
    }

    /// Fixed-width slot so revealing the time never moves the bubble.
    private var timeGutter: some View {
        Text(Fmt.clockTime(message.date))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(width: 58, alignment: message.isFromMe ? .leading : .trailing)
            .opacity(hovering || model.debugShowTimes ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: hovering)
            .padding(.bottom, 8)
            .accessibilityHidden(true)
    }

}

struct AttachmentChip: View {
    let attachment: Attachment

    var body: some View {
        Group {
            if let url = attachment.linkURL {
                Link(destination: url) { label }
            } else {
                label
            }
        }
        .buttonStyle(.plain)
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.symbolName)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.summary).font(.callout).lineLimit(2)
                if let d = attachment.description, !d.isEmpty, attachment.type == "link_preview" || attachment.type == "post_share" {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let t = attachment.originalText, !t.isEmpty, attachment.type == "post_share" || attachment.type == "forwarded" {
                    Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 420, alignment: .leading)
    }
}

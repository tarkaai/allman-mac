import AppKit
import SwiftUI

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    let snapshot: ConversationSnapshot

    static let timeGutter: CGFloat = 76
    @State private var reveal: CGFloat = 0

    private enum Row: Identifiable {
        case stamp(Date)
        case message(Message, showsTail: Bool)
        var id: String {
            switch self {
            case .stamp(let d): return "stamp-\(d.timeIntervalSince1970)"
            case .message(let m, _): return m.id
            }
        }
    }

    var body: some View {
        let inbox = model.inbox
        let convId = snapshot.record.convId
        let messages = inbox.messages[convId] ?? []
        let rows = rows(for: messages)
        VStack(spacing: 0) {
            GeometryReader { geo in
            let maxBubble = max(260, (geo.size.width - 32) * 0.6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if inbox.backfilling.contains(convId) {
                            HStack { Spacer(); ProgressView().controlSize(.small); Text("Loading older history…").font(.caption).foregroundStyle(.secondary); Spacer() }
                                .padding(.vertical, 6)
                        }
                        ForEach(rows) { row in
                            switch row {
                            case .stamp(let date):
                                TimeStamp(date: date).padding(.vertical, 10)
                            case .message(let msg, let tail):
                                MessageRow(
                                    message: msg,
                                    contactName: snapshot.record.displayName,
                                    showsTail: tail,
                                    reveal: model.debugShowTimes ? Self.timeGutter : reveal,
                                    maxWidth: maxBubble,
                                    onReact: { emoji in Task { await inbox.react(msg, in: convId, emoji: emoji) } },
                                    onReply: { inbox.replyingTo[convId] = msg }
                                )
                                .id(msg.id)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .background(TimeRevealGesture(reveal: $reveal, maxReveal: Self.timeGutter))
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
            .sharedBackgroundVisibility(.hidden)
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
    }

    /// iMessage grouping: a centered stamp whenever more than an hour passes,
    /// and a tail only on the last bubble of a run from the same side.
    private func rows(for messages: [Message]) -> [Row] {
        var out: [Row] = []
        var prev: Message?
        for (i, m) in messages.enumerated() {
            if let p = prev {
                if m.timestamp - p.timestamp > 60 * 60 * 1000 { out.append(.stamp(m.date)) }
            } else {
                out.append(.stamp(m.date))
            }
            let next = i + 1 < messages.count ? messages[i + 1] : nil
            let tail = next == nil || next!.isFromMe != m.isFromMe || next!.timestamp - m.timestamp > 60 * 60 * 1000
            out.append(.message(m, showsTail: tail))
            prev = m
        }
        return out
    }
}

struct TimeStamp: View {
    let date: Date
    var body: some View {
        let s = Fmt.threadStamp(date)
        HStack(spacing: 4) {
            Text(s.day).fontWeight(.semibold)
            Text(s.time)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }
}

enum BubbleStyle {
    static let outgoing = Color(nsColor: .systemBlue)
    static let incoming = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.235, alpha: 1)                    // iMessage dark gray
            : NSColor(red: 0.914, green: 0.914, blue: 0.922, alpha: 1) // iMessage light gray
    })
    static let radius: CGFloat = 18
}

struct MessageRow: View {
    let message: Message
    let contactName: String
    let showsTail: Bool
    let reveal: CGFloat
    let maxWidth: CGFloat
    let onReact: (String) -> Void
    let onReply: () -> Void

    @State private var hovering = false
    @State private var showingPicker = false

    /// Width of the react button plus its spacing in the reactions row.
    static let reactButtonSlot: CGFloat = 28

    var body: some View {
        let mine = message.isFromMe
        let hasReactions = !message.reactions.isEmpty
        HStack(alignment: .bottom, spacing: 0) {
            if mine { Spacer(minLength: 0) }
            bubble
                .overlay(alignment: mine ? .bottomLeading : .bottomTrailing) {
                    // The pill lands on the bubble corner; the (hover-only) smiley hangs just outside it.
                    reactionsRow
                        .fixedSize() // never squeeze to a narrow bubble's width
                        .offset(x: mine ? -Self.reactButtonSlot + 6 : Self.reactButtonSlot - 6, y: 13)
                }
                .overlay(RightClickCatcher { showingPicker = true })
                .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                    ReactionPicker(
                        message: message,
                        onReact: { showingPicker = false; onReact($0) },
                        onReply: { showingPicker = false; onReply() },
                        onCopy: {
                            showingPicker = false
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.body, forType: .string)
                        }
                    )
                }
                .frame(maxWidth: maxWidth, alignment: mine ? .trailing : .leading)
                // Only your own bubbles slide; the other side stays put (iMessage).
                .offset(x: mine ? -reveal : 0)
            if !mine { Spacer(minLength: 0) }
        }
        .overlay(alignment: .bottomTrailing) {
            // Parked past the trailing edge; the swipe gesture slides it into view.
            Text(Fmt.clockTime(message.date))
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: ThreadView.timeGutter, alignment: .center)
                .padding(.bottom, 6)
                .offset(x: ThreadView.timeGutter - reveal)
                .allowsHitTesting(false)
        }
        .padding(.bottom, (hasReactions ? 16 : 0) + (showsTail ? 6 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityLabel("\(mine ? "You" : contactName), \(Fmt.clockTime(message.date)): \(message.previewText)")
    }

    private var bubble: some View {
        let mine = message.isFromMe
        let replied = message.attachments.first { $0.type == "replied" }
        return VStack(alignment: .leading, spacing: 6) {
            if let replied {
                QuoteBlock(attachment: replied, onBlue: mine)
            }
            if let subject = message.subject, !subject.isEmpty {
                Text(subject).font(.callout.weight(.semibold))
            }
            if !message.body.isEmpty {
                Text(Links.attributed(message.body, onBlue: mine))
                    .textSelection(.enabled)
                    .tint(mine ? .white : Color(nsColor: .linkColor))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, a in
                if a.type == "link_preview" || a.type == "post_share" {
                    LinkPreviewCard(attachment: a, onBlue: mine)
                } else if a.type != "replied" {
                    AttachmentChip(attachment: a, onBlue: mine)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .foregroundStyle(mine ? .white : .primary)
        .background(mine ? BubbleStyle.outgoing : BubbleStyle.incoming, in: RoundedRectangle(cornerRadius: BubbleStyle.radius, style: .continuous))
    }

    /// Existing reactions (LinkedIn-style pill over the bubble edge) with the
    /// react button right beside them on hover.
    private var reactionsRow: some View {
        let mine = message.isFromMe
        return HStack(spacing: 4) {
            if mine { reactButton }
            if !message.reactions.isEmpty { reactionsPill }
            if !mine { reactButton }
        }
    }

    private var reactionsPill: some View {
        HStack(spacing: 2) {
            ForEach(message.reactions, id: \.emoji) { r in
                Button { onReact(r.emoji) } label: {
                    HStack(spacing: 2) {
                        Text(r.emoji).font(.system(size: 12))
                        if r.count > 1 { Text("\(r.count)").font(.caption2.weight(.semibold)).monospacedDigit() }
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(r.hasUserReacted ? Color(nsColor: .systemBlue).opacity(0.18) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(r.hasUserReacted ? "Remove your \(r.emoji)" : "React with \(r.emoji)")
            }
        }
        .padding(2)
        .background(.background, in: Capsule())
        .overlay(Capsule().stroke(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .foregroundStyle(.primary)
    }

    private var reactButton: some View {
        Button { showingPicker = true } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.background, in: Circle())
                .overlay(Circle().stroke(Color(nsColor: .separatorColor)))
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .opacity(hovering || showingPicker ? 1 : 0)
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .help("React")
    }
}

/// The quoted original on a LinkedIn "reply" message.
struct QuoteBlock: View {
    let attachment: Attachment
    let onBlue: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(onBlue ? Color.white.opacity(0.7) : Color(nsColor: .systemBlue)).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.authorName ?? "Replying to").font(.caption.weight(.semibold)).opacity(0.9)
                Text(attachment.originalText ?? "").font(.callout).lineLimit(3).opacity(0.85)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(onBlue ? Color.white.opacity(0.15) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: 360, alignment: .leading)
    }
}

/// LinkedIn-generated preview data (title, description, image) rendered as a card.
struct LinkPreviewCard: View {
    let attachment: Attachment
    let onBlue: Bool
    @State private var image: NSImage?

    var body: some View {
        let url = attachment.linkURL
        Group {
            if let url {
                Link(destination: url) { card }
            } else {
                card
            }
        }
        .buttonStyle(.plain)
        .task(id: attachment.previewUrl) {
            image = nil
            guard let p = attachment.previewUrl, let u = URL(string: p) else { return }
            image = await ImageCache.shared.image(for: u)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 150).clipped()
            }
            VStack(alignment: .leading, spacing: 2) {
                if let t = attachment.title ?? attachment.authorName.map({ "Post by \($0)" }) {
                    Text(t).font(.callout.weight(.semibold)).lineLimit(2)
                }
                if let d = attachment.description ?? attachment.originalText, !d.isEmpty {
                    Text(d).font(.caption).lineLimit(3).opacity(0.85)
                }
                if let host = attachment.linkURL?.host {
                    Text(host.replacingOccurrences(of: "www.", with: "")).font(.caption2).opacity(0.7)
                }
            }
            .padding(10)
        }
        .frame(width: 300, alignment: .leading)
        .background(onBlue ? Color.white.opacity(0.15) : Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(onBlue ? Color.white.opacity(0.25) : Color(nsColor: .separatorColor)))
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    var onBlue = false

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
                if let t = attachment.originalText, !t.isEmpty, attachment.type == "forwarded" || attachment.type == "replied" {
                    Text(t).font(.caption).opacity(0.8).lineLimit(3)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(onBlue ? Color.white.opacity(0.15) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 420, alignment: .leading)
    }
}

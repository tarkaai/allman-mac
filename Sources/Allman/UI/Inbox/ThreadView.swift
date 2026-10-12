import AppKit
import SwiftUI

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    let snapshot: ConversationSnapshot

    static let timeGutter: CGFloat = 76
    @State private var reveal: CGFloat = 0
    /// True while the freshly opened thread is still growing (images, previews):
    /// the bottom stays pinned without animation. After that, growth from new
    /// messages is scrolled into view *with* animation so the stream slides up.
    @State private var settling = true
    /// Declarative scroll target: a request made here is applied by SwiftUI after
    /// the next layout, so scrolling to a row that was just added always lands.
    @State private var position = ScrollPosition(edge: .bottom)
    /// Rows are laid out eagerly (a lazy stack only measures rows once they are
    /// on screen, so scrolling to a row that was just appended below the viewport
    /// never lands). Long threads are capped and extended on demand.
    @State private var visibleLimit = ThreadView.pageSize
    static let pageSize = 300
    /// A search hit the thread just jumped to; its bubble glows briefly.
    @State private var highlightedUrn: String?
    /// Scrolled to (near) the newest message. A width change (panel, resize) re-pins when true.
    @State private var atBottom = true
    /// While set, a pane-width change is in progress and the bottom is held, whatever the
    /// intermediate geometry says (rows re-wrap before the new width is reported).
    @State private var holdBottomUntil = Date.distantPast

    private enum Row: Identifiable {
        case stamp(Date)
        case message(Message, showsTail: Bool, sender: String?)
        case outgoing(InboxModel.OutgoingMessage)
        var id: String {
            switch self {
            case .stamp(let d): return "stamp-\(d.timeIntervalSince1970)"
            case .message(let m, _, _): return m.id
            case .outgoing(let o): return "outgoing-\(o.id)"
            }
        }
    }

    var body: some View {
        let inbox = model.inbox
        let convId = snapshot.record.convId
        let allMessages = inbox.messages[convId] ?? []
        let messages = Array(allMessages.suffix(visibleLimit))
        let hiddenCount = allMessages.count - messages.count
        let outgoing = inbox.outgoingMessages(convId)
        let rows = rows(for: messages, outgoing: outgoing)
        VStack(spacing: 0) {
            ReminderBanner(convId: convId).padding(.top, 6)
            GeometryReader { geo in
            let maxBubble = max(260, (geo.size.width - 32) * 0.6)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if hiddenCount > 0 {
                            HStack {
                                Spacer()
                                Button("Show \(min(hiddenCount, Self.pageSize)) earlier message\(min(hiddenCount, Self.pageSize) == 1 ? "" : "s")") {
                                    visibleLimit += Self.pageSize
                                }
                                .buttonStyle(.glass).controlSize(.small)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        if inbox.backfilling.contains(convId) {
                            HStack { Spacer(); ProgressView().controlSize(.small); Text("Loading older history…").font(.caption).foregroundStyle(.secondary); Spacer() }
                                .padding(.vertical, 6)
                        }
                        ForEach(rows) { row in
                            switch row {
                            case .stamp(let date):
                                TimeStamp(date: date).padding(.vertical, 10)
                            case .message(let msg, let tail, let sender):
                                MessageRow(
                                    message: msg,
                                    contactName: snapshot.record.displayName,
                                    showsTail: tail,
                                    senderName: sender,
                                    reveal: model.debugShowTimes ? Self.timeGutter : reveal,
                                    maxWidth: maxBubble,
                                    media: inbox.media[convId] ?? [:],
                                    mediaLoading: inbox.mediaLoading.contains(convId),
                                    highlighted: highlightedUrn == msg.urn,
                                    onReact: { emoji in Task { await inbox.react(msg, in: convId, emoji: emoji) } },
                                    onReply: { inbox.replyingTo[convId] = msg }
                                )
                                .id(msg.id)
                            case .outgoing(let item):
                                MessageRow(
                                    message: item.asMessage,
                                    contactName: snapshot.record.displayName,
                                    showsTail: true,
                                    reveal: model.debugShowTimes ? Self.timeGutter : reveal,
                                    maxWidth: maxBubble,
                                    media: item.localMedia,
                                    pending: item.state,
                                    onReact: { _ in },
                                    onReply: {},
                                    onRetry: { inbox.retry(item.id, in: convId) },
                                    onDiscard: { inbox.discardOutgoing(item.id, in: convId) }
                                )
                                .id("outgoing-\(item.id)")
                                // Rises out of the composer into the stream, like Messages.
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .identity))
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom").uiProbe("thread-bottom")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .contentMargins(.top, 14, for: .scrollContent)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { old, new in
                    // Only the user's scrolling moves this flag. While the pane changes width
                    // (panel, resize) rows re-wrap and the offset is in flux; the latched value
                    // keeps the bottom anchored through the change.
                    // Content re-wraps (new height) before the container reports its new width.
                    guard Date() >= holdBottomUntil, old.containerSize == new.containerSize, old.contentSize == new.contentSize else { return }
                    atBottom = new.visibleRect.maxY >= new.contentSize.height - 48
                    if UIProbeRegistry.enabled { NSLog("thread: geometry visible=\(Int(new.visibleRect.minY))…\(Int(new.visibleRect.maxY)) content=\(Int(new.contentSize.height)) container=\(Int(new.containerSize.width))x\(Int(new.containerSize.height)) atBottom=\(atBottom)") }
                }
                .onChange(of: geo.size.width) { _, _ in
                    // Rows re-wrap while the pane animates; snap (no animation of our own) to the
                    // newest message over the next frames so the bottom stays in view throughout.
                    if UIProbeRegistry.enabled { NSLog("thread: width change atBottom=\(atBottom)") }
                    guard atBottom else { return }
                    let alreadyHolding = Date() < holdBottomUntil
                    holdBottomUntil = Date().addingTimeInterval(0.7)
                    guard !alreadyHolding else { return }
                    Task { @MainActor in
                        while Date() < holdBottomUntil {
                            proxy.scrollTo("bottom", anchor: .bottom)
                            try? await Task.sleep(for: .milliseconds(40))
                        }
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                // Bottom-anchored, not scrolled-to: the scroll view is rebuilt once the
                // thread has content, so its initial offset is the newest message, and
                // the bottom stays anchored while images and previews grow the content
                // afterwards. No programmatic scrolling on open at all.
                .id(messages.isEmpty ? "empty" : "loaded")
                .scrollPosition($position)
                .defaultScrollAnchor(.bottom)
                // While at the newest message, any size change (a panel opening, the window
                // resizing, the composer growing) keeps it there — anchored, not re-scrolled.
                .defaultScrollAnchor(settling || atBottom ? .bottom : nil, for: .sizeChanges)
                .uiProbe("thread-scroll")
                .background(TimeRevealGesture(reveal: $reveal, maxReveal: Self.timeGutter))
                .task(id: messages.isEmpty) {
                    // Pin the bottom while the first layout settles, then hand over to animated scrolling.
                    settling = true
                    guard !messages.isEmpty else { return }
                    try? await Task.sleep(for: .milliseconds(1200))
                    settling = false
                }
                .onChange(of: messages.count) { old, new in
                    // A message arrived (or ours was stored): the stream slides up to it.
                    if old > 0, new > old { slideToBottom(proxy, .easeOut(duration: 0.25)) }
                }
                .onChange(of: outgoing.count) { old, new in
                    // Our bubble rises out of the composer and everything above moves up with it.
                    if new > old { slideToBottom(proxy, .spring(duration: 0.4, bounce: 0.1)) }
                }
                .onChange(of: inbox.scrollTarget?.token) { _, _ in jumpIfNeeded(proxy, all: allMessages) }
                .onChange(of: allMessages.isEmpty) { _, empty in if !empty { jumpIfNeeded(proxy, all: allMessages) } }
                .onAppear { jumpIfNeeded(proxy, all: allMessages) }
                .overlay {
                    // `messages[convId] == nil` means not read from disk yet — don't flash "no messages".
                    if messages.isEmpty && (inbox.messages[convId] == nil || inbox.loadingThread.contains(convId)) { ProgressView() }
                    else if messages.isEmpty && !inbox.backfilling.contains(convId) {
                        ContentUnavailableView("No messages stored yet", systemImage: "text.bubble", description: Text("Say hello below, or load the history from LinkedIn."))
                    }
                }
            }
            }
            ComposerView(convId: convId, firstName: snapshot.record.shortName)
        }
        .navigationTitle("")
    }

    /// Scrolls after the new row has been laid out, so the offset change itself
    /// animates (the stream visibly moves up) instead of snapping.
    private func slideToBottom(_ proxy: ScrollViewProxy, _ animation: Animation) {
        settling = false
        withAnimation(animation) { position.scrollTo(edge: .bottom) }
        // The declarative request can resolve against the pre-insertion geometry
        // (seen in Release builds); re-issue imperatively over the next frames —
        // once it has landed the extra calls are no-ops.
        Task { @MainActor in
            for ms in [30, 90, 200, 450] {
                try? await Task.sleep(for: .milliseconds(ms))
                withAnimation(animation) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// A search hit was opened: make sure its row is rendered (it may be past the
    /// visible page), scroll it to the middle, and flash it.
    private func jumpIfNeeded(_ proxy: ScrollViewProxy, all: [Message]) {
        let inbox = model.inbox
        guard let target = inbox.scrollTarget, target.convId == snapshot.record.convId, !all.isEmpty else { return }
        guard let idx = all.firstIndex(where: { $0.urn == target.urn }) else { return }
        let hidden = all.count - visibleLimit
        if idx < hidden {
            let needed = all.count - idx + 40
            visibleLimit = ((needed + Self.pageSize - 1) / Self.pageSize) * Self.pageSize
        }
        settling = false
        inbox.consumeScrollTarget()
        let urn = target.urn
        Task { @MainActor in
            for ms in [60, 200, 450] {
                try? await Task.sleep(for: .milliseconds(ms))
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(urn, anchor: .center) }
            }
            withAnimation(.easeIn(duration: 0.2)) { highlightedUrn = urn }
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.easeOut(duration: 0.6)) { if highlightedUrn == urn { highlightedUrn = nil } }
        }
    }

    /// One day divider per calendar day, and a tail only on the last bubble
    /// of a run from the same side.
    private func rows(for messages: [Message], outgoing: [InboxModel.OutgoingMessage] = []) -> [Row] {
        var out: [Row] = []
        var prev: Message?
        let cal = Calendar.current
        for (i, m) in messages.enumerated() {
            if let p = prev {
                if !cal.isDate(m.date, inSameDayAs: p.date) { out.append(.stamp(m.date)) }
            } else {
                out.append(.stamp(m.date))
            }
            let next = i + 1 < messages.count ? messages[i + 1] : nil
            let tail = next == nil || next!.isFromMe != m.isFromMe || next!.timestamp - m.timestamp > 60 * 60 * 1000
            // In a group, name the sender at the start of each run from someone else.
            var sender: String?
            if snapshot.record.isGroupThread, !m.isFromMe {
                let newRun = prev == nil || prev!.isFromMe || prev!.fromUrn != m.fromUrn || m.timestamp - prev!.timestamp > 60 * 60 * 1000
                if newRun { sender = snapshot.record.participant(for: m)?.displayName ?? m.fromName }
            }
            out.append(.message(m, showsTail: tail, sender: sender))
            prev = m
        }
        // Just-sent messages ride at the end, under today's divider if the thread's last day isn't today.
        for o in outgoing {
            if prev.map({ !cal.isDate(o.createdAt, inSameDayAs: $0.date) }) ?? true {
                out.append(.stamp(o.createdAt))
                prev = o.asMessage
            }
            out.append(.outgoing(o))
        }
        return out
    }
}

/// Who you're talking to, on which messenger: name with the LinkedIn mark,
/// their brief (enriched role or headline) and their location, on the toolbar row.
struct PersonHeader: View {
    @Environment(AppModel.self) private var model
    let snapshot: ConversationSnapshot

    var body: some View {
        let r = snapshot.record
        let conn = model.inbox.connection(for: r)
        let brief = r.isGroupThread
            ? "Group · \(r.members.count) people"
            : (conn.map { [$0.title, $0.company].compactMap { $0 }.joined(separator: " at ") }.flatMap { $0.isEmpty ? nil : $0 } ?? r.headline)
        PageHeader(
            avatar: AnyView(ConversationAvatar(record: r, size: 34, fallbackURL: conn?.profilePictureUrl.flatMap(URL.init(string:)))),
            title: r.displayName,
            titleAccessory: AnyView(HStack(spacing: 5) {
                MessengerBadge(size: 13)
                if !r.isGroupThread, let d = degree(r.distance) { Text(d).font(.caption2.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
            }),
            line1: brief,
            onTap: { model.toggleInspector() }
        )
        .help("Contact details (⌥⌘I)")
    }

    private func degree(_ d: String?) -> String? {
        switch d {
        case "DISTANCE_1": return "1st"
        case "DISTANCE_2": return "2nd"
        case "DISTANCE_3": return "3rd"
        default: return nil
        }
    }
}

struct TimeStamp: View {
    let date: Date
    var body: some View {
        Text(Fmt.threadStamp(date).day)
            .font(.caption.weight(.semibold))
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
    /// Shown above the bubble in group threads at the start of someone's run.
    var senderName: String? = nil
    let reveal: CGFloat
    let maxWidth: CGFloat
    var media: [String: URL] = [:]
    var mediaLoading = false
    /// Briefly true after jumping here from a search result.
    var highlighted = false
    /// Set for an optimistic bubble: lighter while sending, "Not Delivered" on failure.
    var pending: InboxModel.OutgoingMessage.State? = nil
    let onReact: (String) -> Void
    let onReply: () -> Void
    var onRetry: () -> Void = {}
    var onDiscard: () -> Void = {}

    @State private var hovering = false
    @State private var showingPicker = false

    /// Width of the react button plus its spacing in the reactions row.
    static let reactButtonSlot: CGFloat = 28

    var body: some View {
        let mine = message.isFromMe
        let hasReactions = !message.reactions.isEmpty
        VStack(alignment: .trailing, spacing: 3) {
        if let senderName, !mine {
            HStack { Text(senderName).font(AFont.micro).foregroundStyle(.secondary).padding(.leading, 12); Spacer(minLength: 0) }
                .padding(.top, 4)
                .uiProbe("sender-caption")
        }
        HStack(alignment: .bottom, spacing: 0) {
            if mine { Spacer(minLength: 0) }
            bubble
                .overlay(alignment: mine ? .topLeading : .topTrailing) {
                    // Apple Messages tapback placement: on the top outer corner, pushed
                    // outward so it never sits over the text. The hover-only smiley
                    // hangs further outside.
                    if interactive {
                        reactionsRow
                            .fixedSize() // never squeeze to a narrow bubble's width
                            .offset(x: mine ? -(Self.reactButtonSlot + 14) : Self.reactButtonSlot + 14, y: -12)
                    }
                }
                .overlay(RightClickCatcher { if interactive { showingPicker = true } })
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
        .padding(.top, hasReactions ? 12 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityLabel("\(mine ? "You" : contactName), \(Fmt.clockTime(message.date)): \(message.previewText)")
        if let pending {
            switch pending {
            case .sending:
                Text("Sending…").font(.caption2).foregroundStyle(.secondary)
            case .failed(let reason):
                HStack(spacing: 8) {
                    Label("Not Delivered", systemImage: "exclamationmark.circle.fill")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.red)
                        .help(reason)
                    Button("Try Again", action: onRetry).buttonStyle(.link).font(.caption2)
                    Button("Delete", action: onDiscard).buttonStyle(.link).font(.caption2).foregroundStyle(.secondary)
                }
                Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
            }
        }
        }
        .padding(.bottom, showsTail ? 6 : 0)
        .allowsHitTesting(true)
    }

    /// Reactions and the picker don't apply to a message LinkedIn hasn't stored yet.
    private var interactive: Bool { pending == nil }

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
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { i, a in
                if a.type == "link_preview" || a.type == "post_share" {
                    LinkPreviewCard(attachment: a, onBlue: mine)
                } else if a.type != "replied" {
                    AttachmentView(
                        attachment: a,
                        fileURL: media[StoreReader.mediaKey(messageUrn: message.urn, index: i)],
                        loading: mediaLoading,
                        onBlue: mine
                    )
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .foregroundStyle(mine ? .white : .primary)
        .background(bubbleColor, in: RoundedRectangle(cornerRadius: BubbleStyle.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BubbleStyle.radius, style: .continuous)
                .stroke(Color.yellow, lineWidth: highlighted ? 2.5 : 0)
                .shadow(color: .yellow.opacity(highlighted ? 0.6 : 0), radius: 8)
        )
    }

    private var bubbleColor: Color {
        guard message.isFromMe else { return BubbleStyle.incoming }
        if case .sending = pending { return BubbleStyle.outgoing.opacity(0.55) } // lighter while in flight
        return BubbleStyle.outgoing
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

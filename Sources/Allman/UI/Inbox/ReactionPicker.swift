import SwiftUI

/// LinkedIn-style picker: three quick reactions, a reply action, and a full emoji grid.
struct ReactionPicker: View {
    let message: Message
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(EmojiData.quick, id: \.self) { e in
                    quickButton(e)
                }
                Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up.circle" : "face.smiling")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .help(expanded ? "Fewer" : "All emoji")
                Divider().frame(height: 22)
                Button(action: onReply) {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                Button(action: onCopy) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(message.body.isEmpty)
                .padding(.horizontal, 4)
            }
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(EmojiData.categories, id: \.name) { cat in
                            Text(cat.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 2), count: 10), spacing: 2) {
                                ForEach(cat.emoji, id: \.self) { e in
                                    Button { onReact(e) } label: {
                                        Text(e).font(.system(size: 18)).frame(width: 30, height: 30)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(width: 330, height: 260)
            }
        }
        .padding(10)
    }

    private func quickButton(_ e: String) -> some View {
        let mine = message.reactions.contains { $0.emoji == e && $0.hasUserReacted }
        return Button { onReact(e) } label: {
            Text(e).font(.system(size: 22)).frame(width: 36, height: 36)
                .background(mine ? Color(nsColor: .systemBlue).opacity(0.18) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .help(mine ? "Remove \(e)" : "React \(e)")
    }
}

/// Reports a right-click on the view it backs, so the reaction popover can open from it.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onRightClick = onRightClick
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) { nsView.onRightClick = onRightClick }

    final class CatcherView: NSView {
        var onRightClick: (() -> Void)?
        override func rightMouseDown(with event: NSEvent) { onRightClick?() }
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only claim right-clicks; everything else (text selection, links) passes through.
            guard let e = NSApp.currentEvent, e.type == .rightMouseDown || e.type == .rightMouseUp else { return nil }
            return super.hitTest(point)
        }
    }
}

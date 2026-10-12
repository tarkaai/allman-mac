import AppKit
import SwiftUI

struct AvatarView: View {
    let url: URL?
    let name: String
    var size: CGFloat = 36

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Circle().fill(color.gradient)
            Text(Fmt.initials(name))
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: (url?.absoluteString ?? "") + "|" + name) { // re-run when the row shows someone else
            image = nil
            guard let url else { return }
            image = await ImageCache.shared.image(for: url)
        }
    }

    private var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .mint, .cyan]
        var h: UInt32 = 2166136261
        for b in name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return palette[Int(h % UInt32(palette.count))]
    }
}

/// A group thread's picture: the members' faces packed inside one avatar-sized
/// circle (two on a diagonal, three in a triangle), each offset from the center,
/// nothing spilling outside. More than three adds a "+N" count.
struct GroupAvatarView: View {
    let members: [Participant]
    var size: CGFloat = 36

    var body: some View {
        let shown = Array(members.prefix(3))
        ZStack {
            Circle().fill(Color.primary.opacity(0.07))
            if shown.isEmpty {
                Image(systemName: "person.2.fill").font(.system(size: size * 0.4)).foregroundStyle(.secondary)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { i, p in
                let (face, center) = Self.slot(i, of: shown.count, in: size)
                AvatarView(url: p.avatarURL, name: p.displayName, size: face)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: max(1, size * 0.03)))
                    .position(center)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .topTrailing) {
            if members.count > 3 {
                Text("+\(members.count - 3)")
                    .font(.system(size: max(8, size * 0.22), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(Color.secondary, in: Capsule())
                    .overlay(Capsule().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: 4, y: -3)
                    .uiProbe("group-more-badge")
            }
        }
        .uiProbe("group-avatar")
    }

    /// Face diameter and center for slot `i` so that every face sits inside the big circle:
    /// a face of radius r centered `c` from the middle fits when c + r ≤ size / 2.
    static func slot(_ i: Int, of count: Int, in size: CGFloat) -> (CGFloat, CGPoint) {
        let mid = size / 2
        switch count {
        case 1:
            return (size, CGPoint(x: mid, y: mid))
        case 2:
            let face = size * 0.60, c = size * 0.20 / 1.4142   // diagonal offset, c·√2 = 0.20·size
            return (face, i == 0 ? CGPoint(x: mid - c, y: mid - c) : CGPoint(x: mid + c, y: mid + c))
        default:
            let face = size * 0.52, c = size * 0.24   // triangle: top, bottom-left, bottom-right
            let angle = (-90.0 + Double(i) * 120.0) * .pi / 180
            return (face, CGPoint(x: mid + c * cos(angle), y: mid + c * sin(angle)))
        }
    }
}

/// The picture for a conversation: the contact, or the group's members.
struct ConversationAvatar: View {
    let record: ConversationRecord
    var size: CGFloat = 36
    /// Enriched fallback picture for a contact (connections store).
    var fallbackURL: URL? = nil

    var body: some View {
        if record.isGroupThread {
            GroupAvatarView(members: record.members, size: size)
        } else {
            AvatarView(url: record.avatarURL ?? fallbackURL, name: record.displayName, size: size)
        }
    }
}

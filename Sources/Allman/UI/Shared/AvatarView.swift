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

/// A group thread's picture: the first two members, overlapping.
struct GroupAvatarView: View {
    let members: [Participant]
    var size: CGFloat = 36

    var body: some View {
        let small = size * 0.68
        let shown = Array(members.prefix(2))
        ZStack(alignment: .topLeading) {
            if shown.count >= 2 {
                AvatarView(url: shown[0].avatarURL, name: shown[0].displayName, size: small)
                AvatarView(url: shown[1].avatarURL, name: shown[1].displayName, size: small)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: max(1.5, size * 0.05)))
                    .offset(x: size - small, y: size - small)
            } else if let one = shown.first {
                AvatarView(url: one.avatarURL, name: one.displayName, size: size)
            } else {
                ZStack {
                    Circle().fill(Color.gray.gradient)
                    Image(systemName: "person.2.fill").font(.system(size: size * 0.42)).foregroundStyle(.white)
                }
                .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
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

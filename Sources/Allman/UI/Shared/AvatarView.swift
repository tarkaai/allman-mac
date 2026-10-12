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

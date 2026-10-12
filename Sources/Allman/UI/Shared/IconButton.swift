import SwiftUI

/// Every icon button in the app goes through here: one hover treatment (a soft
/// rounded highlight, like the latest Mac apps), one tooltip per button.
struct IconButton: View {
    enum Size {
        /// Inbox bar icons (24×22, 13pt).
        case bar
        /// Top band icons (28×26, 15pt medium).
        case band
        /// The new-message button (30×28, 17pt).
        case large
        /// Anything else: font, width, height.
        case custom(Font, CGFloat, CGFloat)

        var font: Font {
            switch self {
            case .bar: return AFont.icon
            case .band: return .system(size: 15, weight: .medium)
            case .large: return .system(size: 17, weight: .medium)
            case .custom(let f, _, _): return f
            }
        }
        var box: CGSize {
            switch self {
            case .bar: return CGSize(width: 24, height: 22)
            case .band: return CGSize(width: 28, height: 26)
            case .large: return CGSize(width: 30, height: 28)
            case .custom(_, let w, let h): return CGSize(width: w, height: h)
            }
        }
    }

    let symbol: String
    let help: String
    var size: Size = .bar
    /// Accent-tinted (an "on" state such as pinned or panel open).
    var on = false
    var tint: Color? = nil
    var shortcut: KeyEquivalent? = nil
    var modifiers: EventModifiers = []
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let b = Button(action: action) {
            Image(systemName: symbol)
                .font(size.font)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(on ? Color.accentColor : (tint ?? Color.secondary))
                .frame(width: size.box.width, height: size.box.height)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.09 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        if let shortcut { b.keyboardShortcut(shortcut, modifiers: modifiers) } else { b }
    }
}

/// The same hover highlight for icon-shaped controls that aren't plain buttons (menu labels).
struct IconHover: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.09 : 0)))
            .onHover { hovering = $0 }
    }
}

extension View {
    func iconHover() -> some View { modifier(IconHover()) }
}

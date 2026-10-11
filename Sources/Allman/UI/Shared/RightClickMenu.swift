// A per-view context menu that works inside a List row holding several items.
// SwiftUI resolves `.contextMenu` per *row* on macOS, so a grid of pins inside
// one row highlights the whole row and always shows the first pin's menu. This
// claims the right-click (or control-click) itself and pops an NSMenu at the
// pointer, so the table never sees it.

import AppKit
import SwiftUI

struct RightClickMenu: NSViewRepresentable {
    struct Item {
        let title: String
        let action: () -> Void
        init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    }

    /// Resolved at click time so the menu reflects current state (unread, pinned…).
    let items: () -> [Item]

    func makeNSView(context: Context) -> MenuView {
        let v = MenuView()
        v.items = items
        return v
    }

    func updateNSView(_ nsView: MenuView, context: Context) { nsView.items = items }

    final class MenuView: NSView {
        var items: (() -> [Item])?
        private var current: [Item] = []

        override func rightMouseDown(with event: NSEvent) { present(event) }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { present(event) } else { super.mouseDown(with: event) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Claim only secondary clicks; left-clicks and drags pass through to SwiftUI.
            guard let e = NSApp.currentEvent else { return nil }
            let secondary = e.type == .rightMouseDown || e.type == .rightMouseUp
                || ((e.type == .leftMouseDown || e.type == .leftMouseUp) && e.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }

        private func present(_ event: NSEvent) {
            current = items?() ?? []
            guard !current.isEmpty else { return }
            let menu = NSMenu()
            for (i, item) in current.enumerated() {
                let mi = NSMenuItem(title: item.title, action: #selector(fire(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = i
                menu.addItem(mi)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        @objc private func fire(_ sender: NSMenuItem) {
            guard current.indices.contains(sender.tag) else { return }
            current[sender.tag].action()
        }
    }
}

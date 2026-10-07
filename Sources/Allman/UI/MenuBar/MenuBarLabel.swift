import SwiftUI

/// The status item itself: a glyph for the engine state plus an unread count.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let engine = model.engine
        let unread = model.inbox.unreadCount
        HStack(spacing: 3) {
            Image(systemName: engine.isSyncing ? "arrow.triangle.2.circlepath" : engine.status.symbol)
            if unread > 0 { Text("\(unread)").font(.system(size: 12, weight: .medium)).monospacedDigit() }
        }
        .accessibilityLabel("Allman: \(engine.status.label), \(unread) unread")
    }
}

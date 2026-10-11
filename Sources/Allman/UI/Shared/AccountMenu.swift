// The signed-in account, as a control that opens the account switcher: every
// account in the store with its photo, status and unread count, plus
// "Add Account…". Used in the menu bar panel header and the inbox sidebar
// toolbar. A popover rather than a Menu: menus inside a toolbar's principal
// item collapse the whole toolbar into the overflow chevron.

import SwiftUI

struct AccountMenu<Label: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var label: () -> Label
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: { label() }
            .buttonStyle(.plain)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                AccountSwitcher { showing = false }
                    .environment(model)
            }
            .help(model.sessions.count > 1 ? "Switch account" : "Account")
    }
}

struct AccountSwitcher: View {
    @Environment(AppModel.self) private var model
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.sessions) { session in
                Button {
                    model.select(accountId: session.id)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(url: session.avatarURL, name: session.displayName, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.displayName).font(.callout.weight(.medium)).lineLimit(1)
                            Text(subtitle(session)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        if session.unreadCount > 0 {
                            Text("\(session.unreadCount)")
                                .font(.caption2.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor, in: Capsule())
                        }
                        Circle().fill(statusColor(session.engine.status)).frame(width: 8, height: 8)
                            .help(session.engine.status.label)
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .opacity(session.id == model.current?.id ? 1 : 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !model.sessions.isEmpty { Divider().padding(.vertical, 4) }
            Button {
                model.addAccount()
                dismiss()
            } label: {
                Label(model.isAddingAccount ? "Waiting for browser sign-in…" : "Add Account…", systemImage: "person.badge.plus")
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isAddingAccount)
            Button {
                model.openSettings()
                dismiss()
            } label: {
                Label("Accounts Settings…", systemImage: "gearshape")
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .frame(width: 300)
    }

    private func subtitle(_ session: AccountSession) -> String {
        var parts = ["@\(session.slug)"]
        if !session.isAuthenticated { parts.append("signed out") }
        else if session.engine.status.needsAttention { parts.append(session.engine.status.label) }
        else if let h = session.headline { parts.append(h) }
        return parts.joined(separator: " · ")
    }

    private func statusColor(_ status: SyncEngine.Status) -> Color {
        switch status {
        case .live: return .green
        case .connecting, .reconnecting, .idle, .loggingIn: return .yellow
        case .offline: return .gray
        case .needsLogin, .noBinary, .error: return .orange
        }
    }
}

/// Avatar + name + headline for a session, the way the panel and Settings show it.
struct AccountHeader: View {
    let session: AccountSession
    var size: CGFloat = 36
    var showSlug = true

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(url: session.avatarURL, name: session.displayName, size: size)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName).font(.headline).lineLimit(1)
                if let h = session.headline {
                    Text(h).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if showSlug {
                    Text("@\(session.slug) · LinkedIn").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
    }
}

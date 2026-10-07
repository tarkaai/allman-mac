// The menu bar popover: account, live/sync status, unread summary, recent
// activity, and the handful of actions that matter from the menu bar.

import SwiftUI

struct StatusPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var tick = Date()

    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        let engine = model.engine
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            statusSection
            Divider()
            activitySection
            Divider()
            footer
        }
        .frame(width: 380)
        .onReceive(timer) { tick = $0 }
        .task {
            model.openInboxWindow = { openWindow(id: "inbox") }
            model.openSettingsWindow = { openSettings() }
        }
        .onAppear { model.refreshAccountAuth() }
        .animation(.default, value: engine.status)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if let acct = model.account {
                AvatarView(url: acct.auth.imageUrl.flatMap(URL.init(string:)), name: model.accountDisplayName, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.accountDisplayName).font(.headline)
                    Text("@\(acct.slug) · LinkedIn").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 30)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Allman").font(.headline)
                    Text("No LinkedIn account yet").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            StatusBadge(status: model.engine.status, syncing: model.engine.isSyncing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Status + actions

    @ViewBuilder
    private var statusSection: some View {
        let engine = model.engine
        VStack(alignment: .leading, spacing: 8) {
            if engine.status == .noBinary {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The allman CLI isn't installed.").fontWeight(.medium)
                        Text("curl -fsSL https://allman.sh/install.sh | bash").font(.caption.monospaced()).textSelection(.enabled)
                        Text("or choose the binary in Settings.").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                HStack {
                    Button("Settings…") { openSettings() }.buttonStyle(.glass)
                    Button("Try Again") { model.restart() }.buttonStyle(.glass)
                }
            } else if engine.status == .needsLogin || engine.status == .loggingIn {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.status == .loggingIn ? "Finish signing in to LinkedIn in the browser window." : "Sign in to LinkedIn to start syncing.").fontWeight(.medium)
                        Text("Your session stays on this Mac — nothing is sent anywhere else.").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange) }
                HStack {
                    Button(engine.status == .loggingIn ? "Waiting…" : "Sign in to LinkedIn") { engine.login() }
                        .buttonStyle(.borderedProminent)
                        .disabled(engine.status == .loggingIn)
                    if model.account != nil {
                        Button("Open Inbox") { model.openInbox(convId: nil) }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text(engine.isSyncing ? (engine.syncProgress ?? "Syncing…") : (engine.lastSyncSummary ?? "Waiting for first sync"))
                            .lineLimit(2)
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .symbolEffect(.rotate, isActive: engine.isSyncing)
                    }
                    HStack(spacing: 12) {
                        Text("Last sync \(Fmt.relativeSentence(engine.lastSyncAt ?? model.account?.auth.lastSyncDate, now: tick))")
                        if let beat = engine.lastHeartbeatAt, engine.status.isHealthy {
                            Text("· heartbeat \(Fmt.relativeSentence(beat, now: tick))")
                        }
                        if !engine.networkInterface.isEmpty { Text("· \(engine.networkInterface)") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                let unread = model.inbox.unreadCount
                HStack(spacing: 8) {
                    Button {
                        model.inbox.filter = unread > 0 ? .unread : .all
                        if unread > 0, let first = model.inbox.unread.first { model.openInbox(convId: first.record.convId) } else { model.openInbox(convId: nil) }
                    } label: {
                        Label(unread > 0 ? "Inbox · \(unread) unread" : "Open Inbox", systemImage: "tray.full").fixedSize()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("i", modifiers: .command)
                    Button {
                        engine.syncNow(from: "1d")
                    } label: { Label("Sync Now", systemImage: "arrow.clockwise").fixedSize() }
                        .buttonStyle(.glass)
                        .disabled(engine.isSyncing || engine.status == .offline)
                        .keyboardShortcut("r", modifiers: .command)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent activity").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if case .reconnecting(let n) = model.engine.status { Text("retry \(n)").font(.caption2).foregroundStyle(.secondary) }
                if model.inbox.unreadCount > 0 {
                    Button("Mark all read") { model.inbox.markAllSeen() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            let items = model.engine.log.items
            if items.isEmpty {
                Text("Nothing yet — the first sync will show up here.")
                    .font(.callout).foregroundStyle(.tertiary)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items.prefix(30)) { item in
                            ActivityRow(item: item, now: tick) {
                                if let c = item.convId { model.openInbox(convId: c) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 260)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                .toggleStyle(.checkbox)
                .font(.callout)
            Spacer()
            Button("Settings…") { openSettings() }
                .buttonStyle(.plain).font(.callout)
                .keyboardShortcut(",", modifiers: .command)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain).font(.callout)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct StatusBadge: View {
    let status: SyncEngine.Status
    let syncing: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(syncing && status.isHealthy ? "Syncing" : status.label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .help(status.label)
    }

    private var color: Color {
        switch status {
        case .live: return .green
        case .connecting, .reconnecting, .idle, .loggingIn: return .yellow
        case .offline: return .gray
        case .needsLogin, .noBinary, .error: return .orange
        }
    }
}

struct ActivityRow: View {
    let item: ActivityItem
    let now: Date
    var onTap: () -> Void

    var body: some View {
        if item.convId != nil {
            Button(action: onTap) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Open this conversation")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.callout).lineLimit(1)
                if let d = item.detail, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Text(Fmt.relative(item.date, now: now)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
    }

    private var tint: Color {
        switch item.kind {
        case .message: return .accentColor
        case .sent: return .secondary
        case .sync: return .blue
        case .live: return .green
        case .network: return .gray
        case .auth, .warning: return .orange
        case .error: return .red
        }
    }
}

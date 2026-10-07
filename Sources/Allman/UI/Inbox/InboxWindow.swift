import AppKit
import SwiftUI

struct InboxWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var inbox = model.inbox
        NavigationSplitView {
            ConversationListView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
            if let snap = inbox.selected {
                ThreadView(snapshot: snap)
                    .id(snap.record.convId)
            } else if inbox.isLoading {
                ProgressView("Loading conversations…")
            } else if inbox.snapshots.isEmpty {
                ContentUnavailableView {
                    Label("No conversations yet", systemImage: "tray")
                } description: {
                    Text(model.engine.status == .needsLogin ? "Sign in from the menu bar to start syncing." : "The first sync will fill this in.")
                } actions: {
                    if model.engine.status == .needsLogin { Button("Sign in to LinkedIn") { model.engine.login() } }
                }
            } else {
                ContentUnavailableView("Select a conversation", systemImage: "bubble.left.and.bubble.right", description: Text("\(inbox.snapshots.count) conversations · \(inbox.unreadCount) unread"))
            }
        }
        .navigationTitle("Inbox")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.engine.syncNow(from: "1d")
                } label: { Label("Sync Now", systemImage: "arrow.clockwise") }
                    .disabled(model.engine.isSyncing)
                    .help("Sync the last day from LinkedIn (⌘R)")
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(WindowAccessor { window in
            window.identifier = NSUserInterfaceItemIdentifier("inbox")
            window.tabbingMode = .disallowed
        })
        .overlay(alignment: .bottom) {
            if let toast = inbox.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        inbox.toast = nil
                    }
            }
        }
        .animation(.default, value: inbox.toast)
    }
}

/// Grabs the hosting NSWindow so we can tag it and tweak it.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { configure(w) } }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let w = nsView.window { configure(w) } }
    }
}

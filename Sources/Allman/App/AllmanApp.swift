// Allman for Mac — a menu bar companion to the allman LinkedIn messenger CLI.
// Keeps ~/.allman live wherever the Mac goes, and puts a native inbox on top.

import SwiftUI

@main
struct AllmanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    private var model: AppModel { AppModel.shared }

    var body: some Scene {
        MenuBarExtra {
            StatusPanelView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
                .task { model.openInboxWindow = { openWindow(id: "inbox") } }
        }
        .menuBarExtraStyle(.window)

        Window("Inbox", id: "inbox") {
            InboxWindow()
                .environment(model)
        }
        .defaultSize(width: 1080, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Inbox") {
                Button("Sync Now") { model.engine.syncNow(from: "1d") }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Full Re-sync (7 days)") { model.engine.syncNow(from: "7d", resync: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Mark All as Read") { model.inbox.markAllSeen() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Show Unread Only") { model.inbox.filter = model.inbox.filter == .unread ? .all : .unread }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Divider()
                Button("Open Thread on LinkedIn") {
                    if let url = model.inbox.selected?.record.linkedInThreadURL { NSWorkspace.shared.open(url) }
                }
                .disabled(model.inbox.selected == nil)
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

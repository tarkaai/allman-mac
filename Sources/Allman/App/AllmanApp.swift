// Allman for Mac — a menu bar companion to the allman LinkedIn messenger CLI.
// Keeps ~/.allman live wherever the Mac goes, and puts a native inbox on top.
//
// The status item is AppKit (StatusItemController) so a left-click can open the
// inbox and a right-click the panel. The inbox stays a SwiftUI Window scene; AppKit
// opens it by sending the app its own `allman://inbox` URL, which the scene handles.

import SwiftUI

@main
struct AllmanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var model: AppModel { AppModel.shared }

    var body: some Scene {
        Window("Inbox", id: "inbox") {
            InboxWindow()
                .environment(model)
        }
        .defaultSize(width: 1080, height: 700)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: ["inbox"])
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Inbox") {
                Button("New Message…") { model.openInbox(convId: nil); NotificationCenter.default.post(name: .allmanCompose, object: nil) }
                    .keyboardShortcut("n", modifiers: .command)
                Divider()
                Button("Sync Now") { model.engine.syncNow(from: "1d") }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Full Re-sync (7 days)") { model.engine.syncNow(from: "7d", resync: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Next Conversation") { model.inbox.selectNext() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Previous Conversation") { model.inbox.selectPrevious() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Next Unread") { model.inbox.selectNext(unreadOnly: true) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Previous Unread") { model.inbox.selectPrevious(unreadOnly: true) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Divider()
                Button("Search Conversations") { model.inbox.requestFocus(.search) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Go to Message Field") { model.inbox.requestFocus(.composer) }
                    .keyboardShortcut("l", modifiers: .command)
                Button(model.inbox.selectedConvId.map { model.inbox.isPinned($0) } == true ? "Unpin Conversation" : "Pin Conversation") {
                    if let id = model.inbox.selectedConvId { model.inbox.togglePin(id) }
                }
                .disabled(model.inbox.selectedConvId == nil)
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Insert Snippet…") { model.inbox.requestFocus(.composer); model.inbox.showSnippetPicker = true }
                    .disabled(model.inbox.selectedConvId == nil && model.inbox.draft == nil)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Labels…") { model.inbox.showLabelPicker = true }
                    .disabled(model.inbox.selectedConvId == nil)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Snooze / Remind…") { model.inbox.showSnoozePicker = true }
                    .disabled(model.inbox.selectedConvId == nil)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Note…") { model.inbox.showNoteEditor = true }
                    .disabled(model.inbox.selectedConvId == nil)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button(model.inbox.selectedConvId.map { model.inbox.isArchived($0) } == true ? "Unarchive" : "Archive") {
                    if let id = model.inbox.selectedConvId { model.inbox.toggleArchive(id) }
                }
                .disabled(model.inbox.selectedConvId == nil)
                .keyboardShortcut("e", modifiers: .command)
                Button("Undo Last Change") { model.inbox.undo?.action(); model.inbox.undo = nil; model.inbox.toast = nil }
                    .disabled(model.inbox.undo == nil)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Divider()
                Button("Mark All as Read") { model.inbox.markAllSeen() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Show Unread Only") { model.inbox.filter = model.inbox.filter == .unread ? .all : .unread }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Divider()
                Button(model.inspectorVisible ? "Hide Contact Details" : "Show Contact Details") { model.inspectorVisible.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Open Thread on LinkedIn") {
                    if let url = model.inbox.selected?.record.linkedInThreadURL { NSWorkspace.shared.open(url) }
                }
                .disabled(model.inbox.selected == nil)
                .keyboardShortcut("o", modifiers: [.command, .shift])
                if model.sessions.count > 1 {
                    Divider()
                    Picker("Account", selection: Binding(get: { model.currentId ?? "" }, set: { model.select(accountId: $0) })) {
                        ForEach(model.sessions) { s in Text("\(s.displayName) (@\(s.slug))").tag(s.id) }
                    }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

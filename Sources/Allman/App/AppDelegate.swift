import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []
    private(set) var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let model = AppModel.shared
            statusItem = StatusItemController(model: model)
            model.openInboxWindow = { Self.openInboxScene() }
            model.openSettingsWindow = { Self.openSettingsScene() }
            DebugSnapshots.runIfRequested()
        }
        Task { @MainActor in await AppModel.shared.bootstrap() }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow else { return }
            if Self.isNetwork(w) { Task { @MainActor in NSApp.setActivationPolicy(.regular) }; return }
            guard Self.isInbox(w) else { return }
            Task { @MainActor in
                NSApp.setActivationPolicy(.regular)
                let inbox = AppModel.shared.inbox
                inbox.isWindowFocused = true
                if let sel = inbox.selectedConvId {
                    inbox.markSeen(sel)
                    AppModel.shared.notifier.clear(convId: sel)
                }
            }
        })
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow, Self.isInbox(w) else { return }
            Task { @MainActor in AppModel.shared.inbox.isWindowFocused = false }
        })
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow, Self.isInbox(w) else { return }
            Task { @MainActor in
                AppModel.shared.inbox.isWindowFocused = false
                // Back to a pure menu bar app once the last inbox window is gone.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let stillOpen = NSApp.windows.contains { $0 !== w && (Self.isInbox($0) || Self.isNetwork($0)) && $0.isVisible }
                    if !stillOpen { NSApp.setActivationPolicy(.accessory) }
                }
            }
        })
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in AppModel.shared.openInbox(convId: nil) }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.stopAll() }
    }

    /// The Inbox `Window` scene handles external events matching "inbox", so the
    /// app opening its own URL is the supported way to show it from AppKit.
    @MainActor static func openInboxScene() {
        if let w = NSApp.windows.first(where: { isInbox($0) && $0.isVisible }) {
            w.makeKeyAndOrderFront(nil)
            return
        }
        NSWorkspace.shared.open(URL(string: "allman://inbox")!)
    }

    /// SwiftUI's Settings scene is opened by the app menu's own item (macOS 14+ selector).
    @MainActor static func openSettingsScene() {
        NSApp.activate(ignoringOtherApps: true)
        let selectors = ["showSettingsWindow:", "showPreferencesWindow:"].map { Selector($0) }
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let item = appMenu.items.first(where: { $0.action.map(selectors.contains) == true || $0.title.hasPrefix("Settings") }),
           let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
            return
        }
        for sel in selectors where NSApp.sendAction(sel, to: nil, from: nil) { return }
        NSLog("settings: no handler found")
    }

    static func isInbox(_ w: NSWindow) -> Bool {
        w.identifier?.rawValue == "inbox" || w.identifier?.rawValue.hasPrefix("inbox") == true
    }

    static func isNetwork(_ w: NSWindow) -> Bool { w.identifier?.rawValue == "network" }
}

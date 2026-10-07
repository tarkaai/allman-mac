import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in await AppModel.shared.bootstrap() }
        MainActor.assumeIsolated { DebugSnapshots.runIfRequested() }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow, Self.isInbox(w) else { return }
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
                    let stillOpen = NSApp.windows.contains { $0 !== w && Self.isInbox($0) && $0.isVisible }
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
        MainActor.assumeIsolated { AppModel.shared.engine.stop() }
    }

    static func isInbox(_ w: NSWindow) -> Bool {
        w.identifier?.rawValue == "inbox" || w.identifier?.rawValue.hasPrefix("inbox") == true
    }
}

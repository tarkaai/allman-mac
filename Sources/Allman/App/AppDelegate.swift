import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []
    private(set) var statusItem: StatusItemController?
    /// The live delegate (NSApp.delegate is SwiftUI's own wrapper, not this instance).
    private(set) static weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The unit-test host: no window, no status item, no CLI processes — it only hosts XCTest
        // (the mock UI run is a separate process it launches).
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            NSApp.setActivationPolicy(.accessory)
            // The scene's window must stay "open" or SwiftUI quits the host before XCTest
            // connects — so it stays, invisible, off-screen and inert.
            let hide: (NSWindow) -> Void = { w in
                w.alphaValue = 0
                w.ignoresMouseEvents = true
                w.isExcludedFromWindowsMenu = true
                w.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            }
            NSApp.windows.forEach(hide)
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
                if let w = n.object as? NSWindow { hide(w) }
            })
            return
        }
        NSApp.setActivationPolicy(.accessory)
        Self.shared = self
        MainActor.assumeIsolated {
            let model = AppModel.shared
            statusItem = StatusItemController(model: model)
            model.openInboxWindow = { Self.openInboxScene() }
            DebugSnapshots.runIfRequested()
            UIRuleChecks.runIfRequested()
        }
        Task { @MainActor in await AppModel.shared.bootstrap() }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow, Self.isInbox(w) else { return }
            Task { @MainActor in
                if !AppModel.quiet { NSApp.setActivationPolicy(.regular) }
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

    /// A menu bar app: closing the inbox (⌘W, the red button) only closes that window. Without
    /// this SwiftUI's default for a Window-only app is to quit once the last window is gone.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in AppModel.shared.openInbox(convId: nil) }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.stopAll() }
    }

    /// Shows the inbox from AppKit (status item, notifications, menu commands). The window is
    /// re-ordered front when it exists; otherwise the scene's `openWindow` action (captured by
    /// InboxWindow while it was up) recreates it. The `allman://inbox` URL the scene also
    /// handles is the fallback before any window has ever appeared — it goes through
    /// LaunchServices, which may pick a different copy of the app, so it is not the first choice.
    @MainActor static func openInboxScene() {
        if let w = NSApp.windows.first(where: { isInbox($0) && $0.isVisible }) {
            if AppModel.quiet { w.orderFrontRegardless() } else { w.makeKeyAndOrderFront(nil) }
            return
        }
        if let open = AppModel.shared.openInboxScene { open(); return }
        NSWorkspace.shared.open(URL(string: "allman://inbox")!)
    }

    static func isInbox(_ w: NSWindow) -> Bool {
        w.identifier?.rawValue == "inbox" || w.identifier?.rawValue.hasPrefix("inbox") == true
    }
}

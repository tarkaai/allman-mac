// The menu bar item. Left-click opens the inbox window; right-click (or
// control-click) shows the status panel. SwiftUI's MenuBarExtra can't tell the
// two apart, so the item is a plain NSStatusItem with an NSPopover around the
// SwiftUI panel. The glyph and unread count follow the model through
// observation tracking.

import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel
    /// NSApp.delegate is SwiftUI's proxy, not our AppDelegate, so expose the item here.
    private(set) static weak var shared: StatusItemController?

    init(model: AppModel) {
        self.model = model
        super.init()
        Self.shared = self

        let host = NSHostingController(rootView: StatusPanelView().environment(model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Allman — click for the inbox, right-click for status"
            button.imagePosition = .imageLeading
            button.font = NSFont.menuBarFont(ofSize: 0)
        }
        model.closePanel = { [weak self] in self?.closePanel() }
        observe()
    }

    // MARK: Clicks

    @objc private func clicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if secondary {
            togglePanel()
        } else {
            closePanel()
            model.openInbox(convId: nil)
        }
    }

    func togglePanel() {
        if popover.isShown { closePanel() } else { showPanel() }
    }

    func showPanel() {
        guard let button = item.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Buttons and the Launch-at-Login checkbox need key status to react on first click.
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePanel() {
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        item.button?.highlight(false)
    }

    // MARK: Label

    private func observe() {
        withObservationTracking {
            render()
        } onChange: {
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func render() {
        guard let button = item.button else { return }
        let status = model.overallStatus
        let syncing = model.isAnySyncing
        let unread = model.totalUnread
        let symbol = syncing ? "arrow.triangle.2.circlepath" : status.symbol
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: status.label)
        image?.isTemplate = true
        button.image = image
        button.title = unread > 0 ? " \(unread)" : ""
        button.appearsDisabled = false
        button.setAccessibilityLabel("Allman: \(status.label), \(unread) unread")
    }
}

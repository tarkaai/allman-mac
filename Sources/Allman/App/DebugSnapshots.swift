// Dev-only: launch with ALLMAN_SNAPSHOT_DIR=/some/dir to capture the inbox
// window (normal and with timestamps forced visible), the menu bar panel, and
// Settings to PNG, then quit. Capturing our own windows needs no Screen
// Recording permission, so this works from a terminal. No effect otherwise.

import AppKit
import SwiftUI

@MainActor
enum DebugSnapshots {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["ALLMAN_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Task { @MainActor in
            let model = AppModel.shared
            try? await Task.sleep(for: .seconds(8)) // let the store load and the first sync events arrive
            // Prefer a recent thread that has reactions and both sides talking, so the
            // capture exercises pills, quotes and incoming bubbles.
            let reader = model.reader
            let candidates = model.inbox.snapshots.prefix(80)
            let rich = candidates.first { snap in
                guard let dir = model.account?.dir else { return false }
                let msgs = reader.readMessages(accountDir: dir, convId: snap.record.convId)
                return msgs.contains { !$0.reactions.isEmpty } && msgs.contains { !$0.isFromMe } && msgs.count >= 4
            }
            let wanted = ProcessInfo.processInfo.environment["ALLMAN_SNAPSHOT_CONV"]?.lowercased()
            let named = wanted.flatMap { w in model.inbox.snapshots.first { $0.record.displayName.lowercased().contains(w) } }
            // Temporarily pin threads named in ALLMAN_SNAPSHOT_PINS (comma-separated), restored before quitting.
            let originalPins = model.inbox.readState.pins
            if let pinNames = ProcessInfo.processInfo.environment["ALLMAN_SNAPSHOT_PINS"] {
                for n in pinNames.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
                    if let snap = model.inbox.snapshots.first(where: { $0.record.displayName.lowercased().contains(n) }), !model.inbox.isPinned(snap.record.convId) {
                        model.inbox.togglePin(snap.record.convId)
                    }
                }
            }
            // NSApp.terminate never returns, so restore explicitly before quitting (not via defer).
            let restorePins = {
                model.inbox.readState.pinned = originalPins
                model.inbox.readState.save()
            }
            let target = named ?? rich ?? model.inbox.unread.first ?? model.inbox.snapshots.first
            model.openInbox(convId: nil)
            try? await Task.sleep(for: .seconds(3))
            if let w = NSApp.windows.first(where: AppDelegate.isInbox) {
                w.setContentSize(NSSize(width: 1080, height: 700))
                w.center()
            }
            // Cold open of a thread (messages not loaded yet) at a few instants: the
            // viewport must show the newest message in every frame, never the top.
            if let conv = target?.record.convId {
                model.inbox.select(conv)
                for ms in [120, 350, 800, 1600] {
                    try? await Task.sleep(for: .milliseconds(ms))
                    if let w = NSApp.windows.first(where: AppDelegate.isInbox) {
                        capture(w, to: out.appendingPathComponent("open-\(ms)ms.png"))
                    }
                }
            }
            try? await Task.sleep(for: .seconds(2))
            // A *real* send through the CLI, captured as it happens (ALLMAN_SNAPSHOT_SEND=<text>).
            if let text = ProcessInfo.processInfo.environment["ALLMAN_SNAPSHOT_SEND"], !text.isEmpty, let conv = target?.record.convId {
                let start = Date()
                Task { @MainActor in _ = await model.inbox.send(text, to: conv) }
                // Every 100 ms for 5 s: catches the slide, the overlap, and the swap to solid.
                for _ in 0..<50 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if let w = NSApp.windows.first(where: AppDelegate.isInbox) {
                        let t = Int(Date().timeIntervalSince(start) * 1000)
                        capture(w, to: out.appendingPathComponent(String(format: "send-%04dms.png", t)))
                    }
                }
            }
            if ProcessInfo.processInfo.environment["ALLMAN_SNAPSHOT_OUTGOING"] != nil, let conv = target?.record.convId {
                model.inbox.debugInjectOutgoing(conv)
                for ms in [60, 160, 300, 900] {
                    try? await Task.sleep(for: .milliseconds(ms))
                    if let w = NSApp.windows.first(where: AppDelegate.isInbox) { capture(w, to: out.appendingPathComponent("outgoing-\(ms).png")) }
                }
                if let w = NSApp.windows.first(where: AppDelegate.isInbox) { capture(w, to: out.appendingPathComponent("outgoing.png")) }
                model.inbox.discardOutgoing("dbg-1", in: conv); model.inbox.discardOutgoing("dbg-2", in: conv)
            }
            if let w = NSApp.windows.first(where: AppDelegate.isInbox) {
                // Deterministic layout regardless of the restored frame.
                w.setContentSize(NSSize(width: 1080, height: 700))
                w.center()
                try? await Task.sleep(for: .seconds(1))
                capture(w, to: out.appendingPathComponent("inbox.png"))
                // Labels, a note, a snooze and a reminder on the first few threads (ALLMAN_SNAPSHOT_ORGANIZE=1), restored afterwards.
                let originalOrganizer = model.inbox.organizer
                if ProcessInfo.processInfo.environment["ALLMAN_SNAPSHOT_ORGANIZE"] != nil {
                    let rows = model.inbox.snapshots.prefix(8).map(\.record.convId)
                    let hot = model.inbox.addLabel("Hot lead", icon: "flame")!
                    let hiring = model.inbox.addLabel("Hiring", icon: "person.badge.plus")!
                    let ait = model.inbox.addLabel("AI Tinkerers", icon: "sparkles")!
                    if rows.count >= 6 {
                        model.inbox.toggle(label: hot.id, rows[0]); model.inbox.toggle(label: ait.id, rows[0])
                        model.inbox.toggle(label: hiring.id, rows[1])
                        model.inbox.toggle(label: ait.id, rows[2]); model.inbox.toggle(label: hot.id, rows[2]); model.inbox.toggle(label: hiring.id, rows[2])
                        model.inbox.setNote("Met at the GTM track. Wants the deck before Friday.", rows[0])
                        model.inbox.snooze(rows[3], until: Date().addingTimeInterval(-60), hidden: false, note: "Ask about the pilot")
                        model.inbox.snooze(rows[4], until: Date().addingTimeInterval(86_400 * 2), hidden: true)
                        model.inbox.select(rows[0])
                    }
                    model.inbox.toast = nil
                    try? await Task.sleep(for: .seconds(1.5))
                    capture(w, to: out.appendingPathComponent("organize.png"))
                    model.inspectorVisible = true
                    try? await Task.sleep(for: .seconds(1.5))
                    capture(w, to: out.appendingPathComponent("organize-inspector.png"))
                    model.inspectorVisible = false
                    model.inbox.filter = .label(ait.id)
                    try? await Task.sleep(for: .seconds(1))
                    capture(w, to: out.appendingPathComponent("organize-label.png"))
                    model.inbox.filter = .reminders
                    try? await Task.sleep(for: .seconds(1))
                    capture(w, to: out.appendingPathComponent("organize-reminders.png"))
                    model.inbox.filter = .all
                    model.inbox.showLabelPicker = true
                    try? await Task.sleep(for: .seconds(1.2))
                    if let pop = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }) { capture(pop, to: out.appendingPathComponent("organize-labelpicker.png")) }
                    model.inbox.showLabelPicker = false
                    model.inbox.showSnoozePicker = true
                    try? await Task.sleep(for: .seconds(1.2))
                    if let pop = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }) { capture(pop, to: out.appendingPathComponent("organize-snooze.png")) }
                    model.inbox.showSnoozePicker = false
                    try? await Task.sleep(for: .milliseconds(500))
                    model.inbox.organizer = originalOrganizer
                    model.inbox.organizer.save()
                }
                // Snippet picker over the composer (ALLMAN_SNAPSHOT_SNIPPETS=1); temporary snippets, restored afterwards.
                if ProcessInfo.processInfo.environment["ALLMAN_SNAPSHOT_SNIPPETS"] != nil {
                    let originalSnippets = model.snippets.snippets
                    model.snippets.add(name: "Follow up", body: "Hey {firstName}, following up on my note — any thoughts?")
                    model.snippets.add(name: "Thanks for coming", body: "Thanks for coming out to AI Tinkerers, {firstName}! Great to meet someone from {company}.")
                    model.snippets.add(name: "Intro", body: "Hi {firstName}, {me} here. I run the GTM track at AI Tinkerers Seattle and would love to have you.")
                    model.inbox.requestFocus(.composer)
                    try? await Task.sleep(for: .milliseconds(400))
                    model.inbox.showSnippetPicker = true
                    try? await Task.sleep(for: .seconds(1.5))
                    if let pop = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }) { capture(pop, to: out.appendingPathComponent("snippets.png")) }
                    capture(w, to: out.appendingPathComponent("snippets-window.png"))
                    model.inbox.showSnippetPicker = false
                    try? await Task.sleep(for: .milliseconds(400))
                    for s in model.snippets.snippets where !originalSnippets.contains(s) { model.snippets.remove(s.id) }
                }
                // Keyboard navigation (ALLMAN_SNAPSHOT_NAV=1): 18 steps down — the list must follow the selection.
                if ProcessInfo.processInfo.environment["ALLMAN_SNAPSHOT_NAV"] != nil {
                    model.inbox.requestFocus(.list)
                    // From the first row, one step down must not move the list.
                    if let first = model.inbox.navigationOrder.first { model.inbox.select(first.record.convId) }
                    try? await Task.sleep(for: .milliseconds(600))
                    model.inbox.selectNext()
                    try? await Task.sleep(for: .seconds(1))
                    capture(w, to: out.appendingPathComponent("nav-one.png"))
                    for _ in 0..<18 { model.inbox.selectNext(); try? await Task.sleep(for: .milliseconds(60)) }
                    try? await Task.sleep(for: .seconds(1.2))
                    capture(w, to: out.appendingPathComponent("nav-down.png"))
                    for _ in 0..<6 { model.inbox.selectPrevious(); try? await Task.sleep(for: .milliseconds(60)) }
                    try? await Task.sleep(for: .seconds(1))
                    capture(w, to: out.appendingPathComponent("nav-up.png"))
                }
                let hadInspector = model.inspectorVisible
                if model.inbox.selectedConvId == nil, let conv = target?.record.convId { model.inbox.select(conv) }
                model.toggleInspector()
                for ms in [40, 120, 220, 320] {
                    try? await Task.sleep(for: .milliseconds(ms))
                    capture(w, to: out.appendingPathComponent("inspector-open-\(ms)ms.png"))
                }
                try? await Task.sleep(for: .seconds(1))
                capture(w, to: out.appendingPathComponent("inbox-inspector.png"))
                model.toggleInspector()
                for ms in [40, 120, 220, 320] {
                    try? await Task.sleep(for: .milliseconds(ms))
                    capture(w, to: out.appendingPathComponent("inspector-close-\(ms)ms.png"))
                }
                model.inspectorVisible = hadInspector
                try? await Task.sleep(for: .milliseconds(600))
                // Sidebar collapsed (ALLMAN_SNAPSHOT_CHROME=1): the chrome bar moves to the detail, same order.
                if ProcessInfo.processInfo.environment["ALLMAN_SNAPSHOT_CHROME"] != nil {
                    sendKeyEquivalent("s", modifiers: [.control, .command], to: w)
                    try? await Task.sleep(for: .seconds(1))
                    capture(w, to: out.appendingPathComponent("chrome-collapsed.png"))
                    sendKeyEquivalent("s", modifiers: [.control, .command], to: w)
                    try? await Task.sleep(for: .seconds(1))
                    capture(w, to: out.appendingPathComponent("chrome-expanded.png"))
                }
                model.debugShowTimes = true
                try? await Task.sleep(for: .seconds(1))
                capture(w, to: out.appendingPathComponent("inbox-times.png"))
                model.debugShowTimes = false
                model.inbox.filter = .unread
                try? await Task.sleep(for: .seconds(1))
                capture(w, to: out.appendingPathComponent("inbox-unread.png"))
                model.inbox.filter = .all
                // Full-text search (ALLMAN_SNAPSHOT_SEARCH=<query>): the results list, then the thread opened at the first hit.
                if let q = ProcessInfo.processInfo.environment["ALLMAN_SNAPSHOT_SEARCH"], !q.isEmpty {
                    model.inbox.searchText = q
                    try? await Task.sleep(for: .seconds(3))
                    capture(w, to: out.appendingPathComponent("search.png"))
                    if let hit = model.inbox.messageHits.dropFirst(min(3, max(0, model.inbox.messageHits.count - 1))).first {
                        model.inbox.open(hit: hit)
                        try? await Task.sleep(for: .seconds(2))
                        capture(w, to: out.appendingPathComponent("search-hit.png"))
                    }
                    model.inbox.searchText = ""
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if let q = ProcessInfo.processInfo.environment["ALLMAN_SNAPSHOT_COMPOSE"] {
                    model.inbox.composing = true
                    model.inbox.composeQuery = q
                    try? await Task.sleep(for: .seconds(6)) // local + CLI search
                    capture(w, to: out.appendingPathComponent("compose.png"))
                    model.inbox.composing = false
                    try? await Task.sleep(for: .milliseconds(500))
                }
                // Voice note states (ALLMAN_SNAPSHOT_VOICE=1): recording bar, preview bar, then a fake send.
                if ProcessInfo.processInfo.environment["ALLMAN_SNAPSHOT_VOICE"] != nil, let conv = target?.record.convId {
                    model.inbox.select(conv)
                    VoiceRecorder.debugState = .recording
                    model.inbox.voiceDebugTick += 1
                    try? await Task.sleep(for: .seconds(1.5))
                    capture(w, to: out.appendingPathComponent("voice-recording.png"))
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("allman-snapshot-voice.m4a")
                    try? Data(repeating: 0, count: 2048).write(to: tmp)
                    VoiceRecorder.debugState = .recorded(tmp, 12_300)
                    model.inbox.voiceDebugTick += 1
                    try? await Task.sleep(for: .seconds(1.2))
                    capture(w, to: out.appendingPathComponent("voice-preview.png"))
                    VoiceRecorder.debugState = nil
                    model.inbox.voiceDebugTick += 1
                    _ = await model.inbox.sendAudio(tmp, durationMs: 12_300, to: conv)
                    try? await Task.sleep(for: .seconds(2.5))
                    capture(w, to: out.appendingPathComponent("voice-sent.png"))
                }
            }

            // Insights sheet (ALLMAN_SNAPSHOT_INSIGHTS=1).
            if ProcessInfo.processInfo.environment["ALLMAN_SNAPSHOT_INSIGHTS"] != nil, let w = NSApp.windows.first(where: AppDelegate.isInbox) {
                model.show(.insights)
                try? await Task.sleep(for: .seconds(6))
                capture(w, to: out.appendingPathComponent("insights.png"))
                model.show(.messenger)
                try? await Task.sleep(for: .milliseconds(500))
            }

            // The Network window (ALLMAN_SNAPSHOT_NETWORK=1), connections loaded from the store copy.
            if ProcessInfo.processInfo.environment["ALLMAN_SNAPSHOT_NETWORK"] != nil, let w = NSApp.windows.first(where: AppDelegate.isInbox) {
                model.show(.network)
                try? await Task.sleep(for: .seconds(4))
                capture(w, to: out.appendingPathComponent("network.png"))
                model.network.tab = .missing
                try? await Task.sleep(for: .seconds(1.5))
                capture(w, to: out.appendingPathComponent("network-missing.png"))
                model.network.tab = .connections
                model.show(.settings)
                try? await Task.sleep(for: .seconds(2))
                capture(w, to: out.appendingPathComponent("settings-inline.png"))
                model.show(.messenger)
                try? await Task.sleep(for: .milliseconds(500))
            }

            // The real status-item popover (right-click on the menu bar icon).
            if let controller = StatusItemController.shared {
                controller.showPanel()
                try? await Task.sleep(for: .seconds(2))
                if let pop = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }) {
                    capture(pop, to: out.appendingPathComponent("popover.png"))
                }
                controller.closePanel()
            }

            let panel = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            let host = NSVisualEffectView()
            host.material = .popover
            host.state = .active
            host.wantsLayer = true
            host.layer?.cornerRadius = 16
            host.layer?.masksToBounds = true
            let hosting = NSHostingView(rootView: StatusPanelView().environment(model))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: host.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            panel.contentView = host
            panel.setContentSize(hosting.fittingSize)
            panel.center()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(2))
            capture(panel, to: out.appendingPathComponent("panel.png"))

            if let w = NSApp.windows.first(where: AppDelegate.isInbox) {
                model.show(.settings)
                try? await Task.sleep(for: .seconds(2))
                capture(w, to: out.appendingPathComponent("settings.png"))
                model.show(.messenger)
            }

            // Attention state: what the panel looks like when the LinkedIn session is gone.
            model.engine.markNeedsLogin(reason: "LinkedIn session expired")
            panel.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(1))
            panel.setContentSize(hosting.fittingSize)
            try? await Task.sleep(for: .seconds(1))
            capture(panel, to: out.appendingPathComponent("panel-login.png"))
            restorePins()
            NSApp.terminate(nil)
        }
    }

    /// Drives a keyboard shortcut the way a key press would (menu and SwiftUI shortcuts both see it).
    static func sendKeyEquivalent(_ chars: String, modifiers: NSEvent.ModifierFlags, to window: NSWindow) {
        guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: 0) else { return }
        if !window.performKeyEquivalent(with: ev) { NSApp.sendEvent(ev) }
    }

    private typealias WindowImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// The SDK no longer exposes CGWindowListCreateImage, but the OS still ships it;
    /// resolving it at runtime avoids a Screen Recording prompt for our own windows.
    private static let windowImage: WindowImageFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: WindowImageFn.self)
    }()

    static func capture(_ window: NSWindow, to url: URL) {
        let id = UInt32(window.windowNumber)
        var image: CGImage?
        if let fn = windowImage {
            // kCGWindowListOptionIncludingWindow = 1 << 3; kCGWindowImageBoundsIgnoreFraming = 1 << 0, kCGWindowImageBestResolution = 1 << 3
            image = fn(.null, 1 << 3, id, (1 << 0) | (1 << 3))?.takeRetainedValue()
        }
        if image == nil, let content = window.contentView, let frame = content.superview, let layer = frame.layer {
            let scale = window.backingScaleFactor
            let size = frame.bounds.size
            guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.scaleBy(x: scale, y: scale)
            layer.render(in: ctx)
            image = ctx.makeImage()
        }
        guard let image else { NSLog("snapshot: capture failed for \(url.lastPathComponent)"); return }
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }
}

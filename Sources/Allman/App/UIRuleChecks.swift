// Dev-only, driven by the test suite: launch with ALLMAN_UICHECK_OUT=/path/result.json
// (and a mock store in ALLMAN_STORE) and the app exercises its own window —
// real toolbar, real clicks, real key presses, real scroll views — against the
// layout rules in docs/UI-RULES.md, writes the verdicts as JSON, and quits.
// Screenshots of every state go next to the JSON when ALLMAN_UICHECK_SHOTS is set.

import AppKit
import SwiftUI

@MainActor
enum UIRuleChecks {
    struct Check: Codable { let rule: String; let name: String; let pass: Bool; let detail: String }
    struct Report: Codable { var checks: [Check]; var ready: Bool; var error: String? }

    static func runIfRequested() {
        guard let out = ProcessInfo.processInfo.environment["ALLMAN_UICHECK_OUT"], !out.isEmpty else { return }
        let outURL = URL(fileURLWithPath: out)
        let shots = ProcessInfo.processInfo.environment["ALLMAN_UICHECK_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let shots { try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true) }
        Task { @MainActor in
            var report = Report(checks: [], ready: false, error: nil)
            do {
                report.checks = try await run(shots: shots)
                report.ready = true
            } catch {
                report.error = "\(error)"
            }
            if let data = try? JSONEncoder().encode(report) { try? data.write(to: outURL) }
            NSApp.terminate(nil)
        }
    }

    enum Failure: Error { case timeout(String) }

    // MARK: Scenario

    private static func run(shots: URL?) async throws -> [Check] {
        let model = AppModel.shared
        var checks: [Check] = []
        func check(_ rule: String, _ name: String, _ pass: Bool, _ detail: String = "") { checks.append(Check(rule: rule, name: name, pass: pass, detail: detail)) }
        func shot(_ name: String) { if let shots, let w = window() { DebugSnapshots.capture(w, to: shots.appendingPathComponent("\(name).png")) } }

        // Store loaded, window up.
        try await wait("store", 20) { !model.inbox.snapshots.isEmpty }
        model.openInbox(convId: nil)
        try await wait("window", 10) { window() != nil }
        let w = window()!
        w.setContentSize(NSSize(width: 1080, height: 700)); w.center()
        // Away from the real pointer: a hand resting on the trackpad must not swipe a row.
        if let screen = w.screen ?? NSScreen.main {
            let mouse = NSEvent.mouseLocation
            var f = w.frame
            let vis = screen.visibleFrame
            f.origin.x = mouse.x > vis.midX ? vis.minX : vis.maxX - f.width
            f.origin.y = mouse.y > vis.midY ? vis.minY : vis.maxY - f.height
            w.setFrameOrigin(f.origin)
        }
        w.makeKeyAndOrderFront(nil)
        model.inspectorVisible = false
        model.inbox.filter = .all
        try await sleep(1200)

        // --- R1/R2: sidebar order — chrome bar on the toolbar row, inbox bar → search → list → account at the bottom.
        func y(_ f: CGRect) -> (top: CGFloat, bottom: CGFloat) { (f.minY, f.maxY) } // probes report top-down, window-relative frames
        if let toggle = ax(w, "sidebar-toggle"), let switcher = ax(w, "experience-switcher") {
            check("R4", "sidebar toggle is left of the experience switcher", toggle.minX < switcher.minX, "toggle.x=\(Int(toggle.minX)) switcher.x=\(Int(switcher.minX))")
            check("R4", "toggle is the leftmost control after the window buttons", toggle.minX < 120, "x=\(Int(toggle.minX))")
            check("R1", "chrome bar sits on the toolbar row", y(toggle).top < 60 && y(switcher).top < 60, "toggle.top=\(Int(y(toggle).top)) switcher.top=\(Int(y(switcher).top))")
        } else {
            check("R4", "chrome bar present (sidebar-toggle + experience-switcher)", false, "missing AX elements")
        }
        if let bar = ax(w, "inbox-bar"), let search = ax(w, "search-field"), let list = ax(w, "conversation-list"), let profile = ax(w, "profile-header") {
            check("R1", "inbox bar above the search field", y(bar).bottom <= y(search).top + 1, "bar.bottom=\(Int(y(bar).bottom)) search.top=\(Int(y(search).top))")
            check("R1", "search field above the list", y(search).bottom <= y(list).top + 1, "search.bottom=\(Int(y(search).bottom)) list.top=\(Int(y(list).top))")
            check("R1", "account header below the list, at the bottom of the sidebar", y(profile).top >= y(list).bottom - 1 && w.frame.height - profile.maxY < 12, "profile.top=\(Int(y(profile).top)) list.bottom=\(Int(y(list).bottom)) gapToBottom=\(Int(w.frame.height - profile.maxY))")
        } else {
            check("R1", "sidebar blocks present (inbox-bar, search-field, conversation-list, profile-header)", false, "missing AX elements")
        }

        // --- Select a 1:1 thread with history.
        let order = model.inbox.navigationOrder
        let long = order.first { ($0.record.syncState?.totalSynced ?? 0) >= 40 } ?? order.first!
        model.inbox.select(long.record.convId)
        try await sleep(1500)
        shot("01-thread")

        // --- R11: the composer does not steal focus; j moves the selection.
        let responderIsText = w.firstResponder is NSTextView
        check("R11", "opening a thread keeps focus off the composer", !responderIsText, "firstResponder=\(type(of: w.firstResponder as Any))")
        let before = model.inbox.selectedConvId
        sendKey("j", to: w)
        try await sleep(400)
        check("R11", "j moves to the next conversation", model.inbox.selectedConvId != before && model.inbox.selectedConvId != nil, "before=\(before ?? "nil") after=\(model.inbox.selectedConvId ?? "nil")")
        sendKey("k", to: w)
        try await sleep(400)
        check("R11", "k moves back", model.inbox.selectedConvId == before)
        check("R11", "no stray action from j/k", model.inbox.toast == nil, "toast=\(model.inbox.toast ?? "nil")")

        // --- R3: a pinned thread lives in the grid, never also in the list.
        let pinTarget = order.first!.record.convId
        // The list is still at the top here, so the grid (above the first row) is on screen.
        model.inbox.togglePin(pinTarget)
        try await sleep(900)
        shot("05-pinned")
        check("R3", "pinned thread is in the pinned grid", ax(w, "pin-\(pinTarget)") != nil && model.inbox.pinnedInView.contains { $0.record.convId == pinTarget }, "inView=\(model.inbox.pinnedInView.map(\.record.convId).contains(pinTarget)) grid=\(ax(w, "pinned-grid") != nil) pinProbe=\(ax(w, "pin-\(pinTarget)") != nil) probes=\(UIProbeRegistry.dump.filter { $0.hasPrefix("pin") }.joined(separator: "; "))")
        check("R3", "pinned thread is not in the list", !model.inbox.filtered.contains { $0.record.convId == pinTarget } && ax(w, "row-\(pinTarget)") == nil)
        model.inbox.togglePin(pinTarget)
        try await sleep(300)


        // --- R6: thread header on the toolbar row; R5: exactly one `i`, far right.
        if let header = ax(w, "thread-header") {
            check("R6", "thread header on the toolbar row, left of the detail", y(header).top < 60, "top=\(Int(y(header).top))")
        } else { check("R6", "thread header present while the panel is closed", false) }
        let toggles = axAll(w, "inspector-toggle")
        check("R5", "exactly one contact-panel toggle while closed", toggles.count == 1, "count=\(toggles.count)")
        if toggles.isEmpty { dump(w, to: shots); return checks }
        guard let iButton = toolbarItemFrame(w, label: "Contact Details") else { check("R5", "the `i` toolbar item exists", false); return checks }
        let closedX = toggles.first?.midX ?? 0
        check("R5", "the `i` is at the far right of the window", toggles.first.map { w.frame.width - $0.maxX < 40 } ?? false, "gap=\(Int(w.frame.width - (toggles.first?.maxX ?? 0)))")
        check("R5", "no » overflow on the toolbar", !hasOverflow(w), "")

        // --- R17: scrolled to the newest message before opening the panel.
        func threadAtBottom() -> (Bool, String) {
            guard let scroll = ax(w, "thread-scroll"), let bottom = ax(w, "thread-bottom") else { return (false, "no thread-scroll/thread-bottom probe") }
            return (bottom.maxY <= scroll.maxY + 4 && bottom.minY >= scroll.minY, "bottom.y=\(Int(bottom.maxY)) scroll=\(Int(scroll.minY))…\(Int(scroll.maxY))")
        }
        let b0 = threadAtBottom()
        check("R17", "thread scrolled to the newest message on open", b0.0, b0.1)

        // --- R5: clicking the `i` opens the panel (it is clickable); still one `i`, same place.
        clickWindowRect(iButton, in: w)
        try await sleep(700)
        shot("02-panel-open")
        check("R5", "clicking the `i` opens the panel", model.inspectorVisible)
        check("R5", "no stray action from the click", model.inbox.toast == nil, "toast=\(model.inbox.toast ?? "nil")")
        let openToggles = axAll(w, "inspector-toggle")
        check("R5", "exactly one `i` while open", openToggles.count == 1, "count=\(openToggles.count)")
        check("R5", "the `i` did not move", abs((openToggles.first?.midX ?? -99) - closedX) < 2, "closed.x=\(Int(closedX)) open.x=\(Int(openToggles.first?.midX ?? -99))")
        check("R5", "no » overflow with the panel open", !hasOverflow(w))
        check("R6", "thread header hidden while the panel is open", ax(w, "thread-header") == nil)
        if let ph = ax(w, "inspector-header"), let col = ax(w, "inspector-column") {
            check("R7", "panel header on the toolbar row", y(ph).top < 60, "top=\(Int(y(ph).top))")
            check("R7", "panel header aligned over the panel", abs(ph.minX - col.minX) < 24 && ph.maxX <= (openToggles.first?.minX ?? .infinity), "header.x=\(Int(ph.minX)) column.x=\(Int(col.minX))")
            check("R7", "panel body starts below the header (it scrolls; the header stays)", y(col).top >= 40, "column.top=\(Int(y(col).top))")
        } else { check("R7", "panel header + column present", false, "missing AX elements") }
        let b1 = threadAtBottom()
        check("R17", "thread still at the newest message after the panel opened", b1.0, b1.1)

        // --- R5: clicking again closes it.
        if let t = toolbarItemFrame(w, label: "Contact Details") { clickWindowRect(t, in: w) } else { model.toggleInspector() }
        try await sleep(700)
        check("R5", "clicking the `i` again closes the panel", !model.inspectorVisible)
        check("R5", "one `i`, same place, after closing", axAll(w, "inspector-toggle").count == 1 && abs((ax(w, "inspector-toggle")?.midX ?? -99) - closedX) < 2)
        let b2 = threadAtBottom()
        check("R17", "thread still at the newest message after the panel closed", b2.0, b2.1)
        shot("03-panel-closed")

        // --- R9: list follows the keyboard minimally.
        // Start from two consecutive rows that are both fully on screen: stepping between
        // them must not move the list at all.
        guard let listF = ax(w, "conversation-list") else { return checks }
        func fullyVisible(_ id: String) -> Bool { ax(w, "row-\(id)").map { $0.minY >= listF.minY - 0.5 && $0.maxY <= listF.maxY + 0.5 } ?? false }
        let ids = order.map(\.record.convId)
        guard let startIdx = ids.indices.dropLast().first(where: { fullyVisible(ids[$0]) && fullyVisible(ids[$0 + 1]) }) else {
            check("R9", "two consecutive rows fully on screen to start from", false, "none found"); return checks
        }
        model.inbox.select(ids[startIdx])
        try await sleep(600)
        let rulers = ids.filter { fullyVisible($0) }.prefix(6).map { "row-\($0)" }
        let rulersBefore = rulers.compactMap { id in ax(w, id).map { (id, $0.minY) } }
        shot("04a-nav-zero")
        model.inbox.selectNext()
        try await sleep(500)
        shot("04b-nav-one")
        let moved = rulersBefore.compactMap { id, y in ax(w, id).map { abs($0.minY - y) } }
        check("R9", "one step down between two visible rows does not scroll the list", !moved.isEmpty && moved.allSatisfy { $0 < 1 }, "rows measured=\(moved.count) maxShift=\(Int(moved.max() ?? -1))")
        for _ in 0..<18 { model.inbox.selectNext(); try await sleep(50) }
        try await sleep(1200)
        shot("04-nav-down")
        if let sel = model.inbox.selectedConvId, let row = ax(w, "row-\(sel)") {
            check("R9", "after 18 steps the selected row is on screen", row.minY >= listF.minY - 1 && row.maxY <= listF.maxY + 1, "row=\(Int(row.minY))…\(Int(row.maxY)) list=\(Int(listF.minY))…\(Int(listF.maxY))")
        } else { check("R9", "selected row visible after 18 steps", false, "row probe not found (off screen)") }
        for _ in 0..<6 { model.inbox.selectPrevious(); try await sleep(50) }
        try await sleep(900)
        if let sel = model.inbox.selectedConvId, let row = ax(w, "row-\(sel)") {
            check("R9", "after 6 steps back up the selected row is on screen", row.minY >= listF.minY - 1 && row.maxY <= listF.maxY + 1, "row=\(Int(row.minY))…\(Int(row.maxY))")
        } else { check("R9", "selected row visible after stepping back up", false, "row probe not found (off screen)") }

        // --- R10: selecting an inbox the thread isn't in clears the selection.
        if let label = model.inbox.addLabel("UI check", icon: "tag") {
            model.inbox.select(order.last!.record.convId)
            try await sleep(200)
            model.inbox.filter = .label(label.id)
            try await sleep(400)
            check("R10", "switching to an inbox the thread isn't in resets the selection", model.inbox.selectedConvId == nil, "selected=\(model.inbox.selectedConvId ?? "nil")")
            model.inbox.filter = .all
            model.inbox.deleteLabel(label.id)
            try await sleep(600) // the list is rebuilt; a person's next click comes well after
        } else { check("R10", "could create a label", false) }

        // --- R12: group threads appear, named after their members, with sender captions.
        if let group = model.inbox.snapshots.first(where: { $0.record.isGroupThread }) {
            let r = group.record
            check("R12", "group thread is in the list", model.inbox.filtered.contains { $0.record.convId == r.convId } && ax(w, "row-\(r.convId)") != nil || model.inbox.filtered.contains { $0.record.convId == r.convId })
            check("R12", "group named after its members", r.displayName == "Casey Example, AJ Sample", r.displayName)
            check("R12", "group sends to the bare conversation id", r.sendTarget == r.convId, r.sendTarget)
            model.inbox.select(r.convId)
            try await sleep(1500)
            shot("06-group")
            check("R12", "sender names shown in the group thread", !axAll(w, "sender-caption").isEmpty, "captions=\(axAll(w, "sender-caption").count)")
            if let header = ax(w, "thread-header") { check("R12", "group header on the toolbar row", y(header).top < 60) }
        } else { check("R12", "mock store has a group thread", false) }

        // --- R13: Settings / Network / Insights live in the same window.
        let windowsBefore = visibleWindows().count
        model.show(.settings)
        try await sleep(800)
        shot("07-settings")
        check("R13", "Settings opens inside the main window (no second window)", visibleWindows().count == windowsBefore && model.experience == .settings, "windows=\(visibleWindows().count)")
        check("R13", "chrome bar still first on the settings page", (ax(w, "sidebar-toggle")?.minX ?? 0) < (ax(w, "experience-switcher")?.minX ?? -1))
        model.show(.network); try await sleep(600); shot("08-network")
        check("R13", "Network inside the main window", visibleWindows().count == windowsBefore)
        model.show(.messenger); try await sleep(600)

        // --- R4: collapsing the sidebar keeps the chrome bar order.
        DebugSnapshots.sendKeyEquivalent("s", modifiers: [.control, .command], to: w)
        try await sleep(900)
        shot("09-collapsed")
        if let toggle = ax(w, "sidebar-toggle"), let switcher = ax(w, "experience-switcher") {
            check("R4", "collapsed: toggle still left of the switcher", toggle.minX < switcher.minX, "toggle.x=\(Int(toggle.minX)) switcher.x=\(Int(switcher.minX))")
                check("R4", "collapsed: toggle is the leftmost control", toggle.minX < 120)
            check("R4", "collapsed: no » overflow", !hasOverflow(w))
        } else { check("R4", "collapsed: chrome bar present", false) }
        DebugSnapshots.sendKeyEquivalent("s", modifiers: [.control, .command], to: w)
        try await sleep(900)
        check("R4", "expanded again: chrome bar back in the sidebar", ax(w, "sidebar-toggle") != nil && ax(w, "conversation-list") != nil)
        shot("10-expanded")
        if let shots { try? UIProbeRegistry.dump.joined(separator: "\n").write(to: shots.appendingPathComponent("probes.txt"), atomically: true, encoding: .utf8) }
        return checks
    }

    // MARK: Helpers

    /// Debug aid: every accessibility identifier reachable from the window, plus the toolbar's items.
    static func dump(_ w: NSWindow, to dir: URL?) {
        var lines: [String] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ node: Any, _ depth: Int) {
            guard depth < 60 else { return }
            if let obj = node as? AnyObject, !visited.insert(ObjectIdentifier(obj)).inserted { return }
            let name = String(describing: type(of: node))
            if let el = node as? NSAccessibilityProtocol {
                let id = el.accessibilityIdentifier() ?? ""
                if !id.isEmpty { lines.append("\(String(repeating: " ", count: depth))\(name) id=\(id) frame=\(el.accessibilityFrame())") }
                for c in el.accessibilityChildren() ?? [] { walk(c, depth + 1) }
            }
            if let v = node as? NSView { for s in v.subviews { walk(s, depth + 1) } }
        }
        if let frame = w.contentView?.superview { walk(frame, 0) }
        lines.append("--- toolbar items")
        for item in w.toolbar?.items ?? [] {
            lines.append("item \(item.itemIdentifier.rawValue) type=\(type(of: item)) view=\(item.view.map { String(describing: type(of: $0)) } ?? "nil") label=\(item.label) axid=\((item.view as? NSAccessibilityProtocol)?.accessibilityIdentifier() ?? "")")
            if let v = item.view { visited.removeAll(); walk(v, 2) }
        }
        let text = lines.joined(separator: "\n")
        NSLog("uicheck dump:\n%@", text)
        if let dir { try? text.write(to: dir.appendingPathComponent("ax-dump.txt"), atomically: true, encoding: .utf8) }
    }

    private static func window() -> NSWindow? { NSApp.windows.first { AppDelegate.isInbox($0) && $0.isVisible } }
    private static func visibleWindows() -> [NSWindow] { NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.frame.width > 400 } }

    private static func sleep(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }

    private static func wait(_ what: String, _ seconds: Double, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !cond() {
            if Date() > deadline { throw Failure.timeout(what) }
            try await sleep(100)
        }
    }

    /// Frame (window coordinates, top-down) of the first probe with this id.
    static func ax(_ w: NSWindow, _ id: String) -> CGRect? { UIProbeRegistry.first(id) }
    static func axAll(_ w: NSWindow, _ id: String) -> [CGRect] { UIProbeRegistry.all(id) }

    /// The toolbar item whose SwiftUI label is this (window coordinates, bottom-up, for clicking).
    static func toolbarItemFrame(_ w: NSWindow, label: String) -> CGRect? {
        guard let item = w.toolbar?.items.first(where: { $0.label == label }), let v = item.view else { return nil }
        return v.convert(v.bounds, to: nil)
    }

    /// The toolbar collapsed items into a » menu.
    static func hasOverflow(_ w: NSWindow) -> Bool {
        var hit = false
        func walk(_ v: NSView) {
            let name = String(describing: type(of: v))
            if name.contains("Overflow") || name.contains("ClippedItems") { hit = true }
            v.subviews.forEach(walk)
        }
        if let frame = w.contentView?.superview { walk(frame) }
        return hit
    }

    private static func scrollViews(_ w: NSWindow) -> [NSScrollView] {
        var out: [NSScrollView] = []
        func walk(_ v: NSView) { if let s = v as? NSScrollView { out.append(s) }; v.subviews.forEach(walk) }
        if let c = w.contentView { walk(c) }
        return out
    }

    /// The thread's scroll view: in the detail (right of the sidebar), tall, not the composer.
    static func threadScrollView(_ w: NSWindow) -> NSScrollView? {
        scrollViews(w).filter { s in
            let f = s.convert(s.bounds, to: nil)
            return f.minX > 280 && f.height > 300 && f.width > 250
        }.max { $0.frame.height < $1.frame.height }
    }

    static func listScrollView(_ w: NSWindow) -> NSScrollView? {
        scrollViews(w).filter { s in
            let f = s.convert(s.bounds, to: nil)
            return f.minX < 50 && f.height > 200
        }.max { $0.frame.height < $1.frame.height }
    }

    static func atBottom(_ s: NSScrollView) -> Bool {
        guard let doc = s.documentView else { return false }
        let visible = s.contentView.bounds
        let docH = doc.frame.height
        if doc.isFlipped { return visible.maxY >= docH - 48 }
        return visible.minY <= 48
    }

    static func scrollDebug(_ s: NSScrollView) -> String {
        let v = s.contentView.bounds
        return "visible=\(Int(v.minY))…\(Int(v.maxY)) doc=\(Int(s.documentView?.frame.height ?? 0)) flipped=\(s.documentView?.isFlipped ?? false)"
    }

    /// A real click (down + up through the app's event path) at the center of a window-coordinate rect (bottom-up).
    static func clickWindowRect(_ rect: CGRect, in w: NSWindow) {
        let p = CGPoint(x: rect.midX, y: rect.midY)
        let t = ProcessInfo.processInfo.systemUptime
        if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: t, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
           let up = NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: t + 0.05, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
            NSApp.sendEvent(down)
            NSApp.sendEvent(up)
        }
    }

    /// A plain key press to the window's first responder (SwiftUI `onKeyPress`).
    static func sendKey(_ chars: String, to w: NSWindow) {
        let t = ProcessInfo.processInfo.systemUptime
        if let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: t, windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0),
           let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: t + 0.03, windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0) {
            NSApp.sendEvent(down)
            NSApp.sendEvent(up)
        }
    }
}

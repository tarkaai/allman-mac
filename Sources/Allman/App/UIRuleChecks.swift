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
        model.resetSidebarState()
        // Away from the real pointer: a hand resting on the trackpad must not swipe a row.
        if let screen = w.screen ?? NSScreen.main {
            let mouse = NSEvent.mouseLocation
            var f = w.frame
            let vis = screen.visibleFrame
            f.origin.x = mouse.x > vis.midX ? vis.minX : vis.maxX - f.width
            f.origin.y = mouse.y > vis.midY ? vis.minY : vis.maxY - f.height
            w.setFrameOrigin(f.origin)
        }
        // Visible but never key or active: it shows once, behind whatever the person is doing.
        w.orderFrontRegardless()
        model.inspectorVisible = false
        model.inbox.filter = .all
        try await sleep(1200)

        // --- R1/R2: sidebar order — chrome bar on the toolbar row, inbox bar → search → list → account at the bottom.
        func y(_ f: CGRect) -> (top: CGFloat, bottom: CGFloat) { (f.minY, f.maxY) } // probes report top-down, window-relative frames
        if let toggle = ax(w, "sidebar-toggle"), let switcher = ax(w, "experience-switcher") {
            check("R4", "sidebar toggle is left of the experience switcher", toggle.minX < switcher.minX, "toggle.x=\(Int(toggle.minX)) switcher.x=\(Int(switcher.minX))")
            check("R4", "toggle is the leftmost control after the window buttons", toggle.minX < 120, "x=\(Int(toggle.minX))")
            check("R1", "chrome bar sits on the top band", y(toggle).top < Chrome.barHeight && y(switcher).top < Chrome.barHeight, "toggle.top=\(Int(y(toggle).top)) switcher.top=\(Int(y(switcher).top))")
            if let sb = ax(w, "sidebar") { check("R3b", "sidebar is full height, over the top band", sb.minY < 1 && w.frame.height - sb.maxY < 1, "sidebar=\(Int(sb.minY))…\(Int(sb.maxY))") }
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
            check("R6", "thread header on the top band, left of the detail", y(header).top < Chrome.barHeight, "top=\(Int(y(header).top))")
            check("R6", "thread header is not jammed against the top edge", y(header).top >= 8, "top=\(Int(y(header).top))")
        } else { check("R6", "thread header present while the panel is closed", false) }
        if let sb = ax(w, "sidebar"), let cb = ax(w, "compose-button"), let sw = ax(w, "experience-switcher") {
            check("R34", "new-message button at the top-right of the sidebar, on the band", cb.maxX <= sb.maxX - 4 && cb.minX > sw.maxX && y(cb).top < Chrome.barHeight, "compose.x=\(Int(cb.minX))…\(Int(cb.maxX)) sidebar.maxX=\(Int(sb.maxX))")
        } else { check("R34", "compose button + sidebar present", false) }
        if let fm = ax(w, "filter-menu"), let title = ax(w, "inbox-title") { check("R25", "filter icon sits left of the inbox title", fm.maxX <= title.minX, "filter.x=\(Int(fm.minX)) title.x=\(Int(title.minX))") } else { check("R25", "filter menu + title present", false) }
        if let cb = ax(w, "compose-button") { check("R15c", "new-message button is a step larger than the bar icons", cb.height >= 26 && cb.width >= 28, "\(Int(cb.width))x\(Int(cb.height))") }
        // R21: the thread's actions sit beside the `i`, same size, same row.
        func actionsInPlace(_ label: String) {
            guard let i = ax(w, "inspector-toggle") else { check("R21", "\(label): `i` present", false); return }
            let ids = ["action-pin", "action-label", "action-snooze", "action-note", "action-archive"]
            let frames = ids.compactMap { ax(w, $0) }
            let sameRow = frames.allSatisfy { abs($0.midY - i.midY) < 1 && abs($0.height - i.height) < 1 && abs($0.width - i.width) < 1 }
            let ordered = zip(frames, frames.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 0.5 } && (frames.last.map { $0.maxX <= i.minX + 0.5 } ?? false)
            check("R21", "\(label): pin·label·snooze·note·archive beside the `i`, same size and row", frames.count == 5 && sameRow && ordered, "found=\(frames.count) i=\(Int(i.minX)),\(Int(i.midY))")
        }
        actionsInPlace("panel closed")
        let headerClosed = ax(w, "thread-header")
        // R28: rows all the same height, avatar vertically centered.
        let visibleRows = order.map(\.record.convId).compactMap { ax(w, "row-\($0)") }.filter { listF0 in listF0.height > 0 }
        if let lf = ax(w, "conversation-list") {
            let inside = visibleRows.filter { $0.minY >= lf.minY - 1 && $0.maxY <= lf.maxY + 1 }
            let heights = inside.map { Int($0.height.rounded()) }
            check("R28", "every conversation row is the same height", inside.count >= 5 && Set(heights).count == 1, "heights=\(Set(heights).sorted())")
            let avatars = axAll(w, "row-avatar").filter { $0.minY >= lf.minY - 1 && $0.maxY <= lf.maxY + 1 }
            let centered = inside.allSatisfy { row in avatars.contains { abs($0.midY - row.midY) < 1.5 } }
            check("R28", "row avatars are vertically centered", !inside.isEmpty && centered, "rows=\(inside.count) avatars=\(avatars.count)")
        }
        let toggles = axAll(w, "inspector-toggle")
        check("R5", "exactly one contact-panel toggle while closed", toggles.count == 1, "count=\(toggles.count)")
        if toggles.isEmpty { dump(w, to: shots); return checks }
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
        let headerW0 = ax(w, "thread-header")?.width ?? 0
        clickProbe("inspector-toggle", in: w)
        // R32: the thread *content* narrows at the pace the panel appears (several widths over the animation,
        // no single jump), and bubbles keep their size — only whitespace moves.
        let bubbleWidths0 = axAll(w, "bubble-shape").map { Int($0.width.rounded()) }
        var widths: [Int] = [], bottoms: [Int] = []
        for _ in 0..<20 { try await sleep(15); widths.append(Int(ax(w, "thread-bottom")?.width ?? 0)); bottoms.append(Int(ax(w, "thread-bottom")?.maxY ?? 0)) }
        check("R32c", "messages do not shift while the panel opens (bottom edge still at every frame)", (bottoms.max() ?? 0) - (bottoms.min() ?? 0) <= 1, "bottomY=\(bottoms)")
        try await sleep(400)
        shot("02-panel-open")
        var distinct = Array(Set(widths)).count
        // A loaded machine can drop most of a 250 ms ease's frames; measure the motion once more before judging.
        if distinct < 3 {
            model.toggleInspector(); try await sleep(700)
            model.toggleInspector(); widths = []
            for _ in 0..<20 { try await sleep(15); widths.append(Int(ax(w, "thread-bottom")?.width ?? 0)) }
            try await sleep(400)
            distinct = Array(Set(widths)).count
        }
        let jumps = zip(widths, widths.dropFirst()).map { abs($1 - $0) }
        check("R32", "opening the panel narrows the thread content gradually, in step with the panel (not a snap)", distinct >= 3 && (jumps.max() ?? 0) < Int(Chrome.panelWidth), "widths=\(widths)")
        let bubbleWidths1 = axAll(w, "bubble-shape").map { Int($0.width.rounded()) }
        check("R32", "bubbles keep their size when the panel opens (only whitespace moves)", bubbleWidths0.sorted() == bubbleWidths1.sorted(), "before=\(bubbleWidths0.sorted().suffix(4)) after=\(bubbleWidths1.sorted().suffix(4))")
        let headerW1 = ax(w, "thread-header")?.width ?? 0
        check("R33", "the thread header keeps its full width when the panel opens (no needless ellipsis)", abs(headerW1 - headerW0) < 2, "width \(Int(headerW0))→\(Int(headerW1))")
        check("R5", "clicking the `i` opens the panel", model.inspectorVisible)
        check("R5", "no stray action from the click", model.inbox.toast == nil, "toast=\(model.inbox.toast ?? "nil")")
        let openToggles = axAll(w, "inspector-toggle")
        check("R5", "exactly one `i` while open", openToggles.count == 1, "count=\(openToggles.count)")
        actionsInPlace("panel open")
        check("R5", "the `i` did not move", abs((openToggles.first?.midX ?? -99) - closedX) < 2, "closed.x=\(Int(closedX)) open.x=\(Int(openToggles.first?.midX ?? -99))")
        check("R5", "no » overflow with the panel open", !hasOverflow(w))
        if let h = ax(w, "thread-header"), let h0 = headerClosed {
            check("R6", "thread header stays exactly where it was while the panel is open", abs(h.minX - h0.minX) < 1 && abs(h.minY - h0.minY) < 1, "x \(Int(h0.minX))→\(Int(h.minX)) y \(Int(h0.minY))→\(Int(h.minY))")
        } else { check("R6", "thread header present while the panel is open", false) }
        check("R7", "the panel has no header of its own", ax(w, "inspector-header") == nil)
        if let col = ax(w, "inspector-column") {
            check("R7", "panel body starts under the band (actions and `i` above it)", y(col).top >= Chrome.barHeight - 1 && y(col).top <= Chrome.barHeight + 1, "column.top=\(Int(y(col).top))")
        } else { check("R7", "panel column present", false) }
        let b1 = threadAtBottom()
        check("R17", "thread still at the newest message after the panel opened", b1.0, b1.1)

        // --- R5: clicking again closes it.
        clickProbe("inspector-toggle", in: w)
        var bottomsClose: [Int] = []
        for _ in 0..<12 { try await sleep(25); bottomsClose.append(Int(ax(w, "thread-bottom")?.maxY ?? 0)) }
        try await sleep(400)
        check("R32c", "messages do not shift while the panel closes", (bottomsClose.max() ?? 0) - (bottomsClose.min() ?? 0) <= 1, "bottomY=\(bottomsClose)")
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
            check("R9", "after 18 steps the selected row is on screen", row.minY >= listF.minY - 1 && row.maxY <= listF.maxY + 1, "row=\(Int(row.minY))…\(Int(row.maxY)) list=\(Int(listF.minY))…\(Int(listF.maxY)) profile=\(ax(w, "profile-header").map { "\(Int($0.minY))…\(Int($0.maxY))" } ?? "-")")
        } else { check("R9", "selected row visible after 18 steps", false, "row probe not found (off screen)") }
        for _ in 0..<6 { model.inbox.selectPrevious(); try await sleep(50) }
        try await sleep(900)
        if let sel = model.inbox.selectedConvId, let row = ax(w, "row-\(sel)") {
            check("R9", "after 6 steps back up the selected row is on screen", row.minY >= listF.minY - 1 && row.maxY <= listF.maxY + 1, "row=\(Int(row.minY))…\(Int(row.maxY))")
        } else { check("R9", "selected row visible after stepping back up", false, "row probe not found (off screen)") }

        // --- R24: a click on a visible row never scrolls the list; a search result opens in place.
        if let visible = ids.first(where: { fullyVisible($0) && $0 != model.inbox.selectedConvId }) {
            let before = ids.filter { fullyVisible($0) }.compactMap { id in ax(w, "row-\(id)").map { (id, $0.minY) } }
            model.inbox.sidebarSelection = visible
            try await sleep(600)
            let moved = before.compactMap { id, yy in ax(w, "row-\(id)").map { abs($0.minY - yy) } }
            check("R24", "clicking a visible row selects it without moving the list", model.inbox.selectedConvId == visible && !moved.isEmpty && moved.allSatisfy { $0 < 1 }, "maxShift=\(Int(moved.max() ?? -1))")
        }
        model.inbox.searchText = "Dakota"
        try await sleep(900)
        if let dakota = model.inbox.filtered.first(where: { $0.record.displayName == "Dakota Shaw" }) {
            let before = ax(w, "row-\(dakota.record.convId)")
            let orderBefore = model.inbox.filtered.map(\.record.convId)
            model.inbox.sidebarSelection = dakota.record.convId
            try await sleep(700)
            shot("04c-search-select")
            let after = ax(w, "row-\(dakota.record.convId)")
            check("R24", "selecting a search result keeps the list order and position", model.inbox.selectedConvId == dakota.record.convId && model.inbox.filtered.map(\.record.convId) == orderBefore && before != nil && after != nil && abs((before?.minY ?? 0) - (after?.minY ?? 99)) < 1, "y \(Int(before?.minY ?? -1))→\(Int(after?.minY ?? -1))")
        } else { check("R24", "search finds Dakota", false) }
        model.inbox.searchText = ""
        try await sleep(600)
        // --- R24b: a new message to someone with a thread opens that thread, highlighted and on screen.
        model.inbox.startDraft(DraftRecipient(slug: "blake-rivera", name: "Blake Rivera", headline: nil, avatarURL: nil))
        try await sleep(1000)
        shot("04d-draft-existing")
        if let blake = model.inbox.snapshots.first(where: { $0.record.slug == "blake-rivera" }) {
            let row = ax(w, "row-\(blake.record.convId)")
            check("R24b", "new message to an existing contact opens their thread, highlighted and visible", model.inbox.draft == nil && model.inbox.selectedConvId == blake.record.convId && model.inbox.sidebarSelection == blake.record.convId && row.map { $0.minY >= listF.minY - 1 && $0.maxY <= listF.maxY + 1 } == true, "row=\(row.map { "\(Int($0.minY))…\(Int($0.maxY))" } ?? "nil")")
        }
        // --- R22: "Needs my reply" treats your reaction as a reply.
        model.inbox.filter = .needsReply
        try await sleep(500)
        let reacted = ids.first { $0.hasPrefix("2-MOCK02") }, unanswered = ids.first { $0.hasPrefix("2-MOCK03") }
        check("R22", "Needs my reply: a thread whose last message you reacted to is out, an unanswered one is in", reacted.map { r in !model.inbox.filtered.contains { $0.record.convId == r } } == true && unanswered.map { u in model.inbox.filtered.contains { $0.record.convId == u } } == true, "count=\(model.inbox.filtered.count)")
        // --- R23: pins stay whatever the filter.
        if let first = ids.first {
            model.inbox.togglePin(first)
            model.inbox.filter = .unread
            try await sleep(700)
            shot("05b-pins-under-filter")
            check("R23", "pinned threads stay in the sidebar under the Unread filter", model.inbox.pinnedInView.contains { $0.record.convId == first } && ax(w, "pin-\(first)") != nil, "inView=\(model.inbox.pinnedInView.count)")
            model.inbox.filter = .all
            model.inbox.togglePin(first)
            try await sleep(400)
        }

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
        if let three = model.inbox.snapshots.first(where: { $0.record.members.count == 3 }) {
            model.inbox.select(three.record.convId, reveal: true)
            try await sleep(1200)
            shot("06b-group-three")
            check("R27", "a three-person group is named after all three", three.record.displayName == "Priya Example, Theo Sample, Ro Example", three.record.displayName)
            check("R27", "a three-person group shows all three faces inside one avatar circle (no +N needed)", !axAll(w, "group-avatar").isEmpty && axAll(w, "group-more-badge").isEmpty, "avatars=\(axAll(w, "group-avatar").count) badges=\(axAll(w, "group-more-badge").count)")
        } else { check("R27", "mock store has a three-person group", false) }
        if let group = model.inbox.snapshots.first(where: { $0.record.members.count == 2 }) {
            let r = group.record
            check("R12", "group thread is in the list", model.inbox.filtered.contains { $0.record.convId == r.convId } && ax(w, "row-\(r.convId)") != nil || model.inbox.filtered.contains { $0.record.convId == r.convId })
            check("R12", "group named after its members", r.displayName == "Priya Example, Theo Sample", r.displayName)
            check("R12", "group sends to the bare conversation id", r.sendTarget == r.convId, r.sendTarget)
            model.inbox.select(r.convId)
            try await sleep(1500)
            shot("06-group")
            check("R12", "sender names shown in the group thread", !axAll(w, "sender-caption").isEmpty, "captions=\(axAll(w, "sender-caption").count)")
            if let header = ax(w, "thread-header") { check("R12", "group header on the top band", y(header).top < Chrome.barHeight) }
        } else { check("R12", "mock store has a group thread", false) }

        // --- R13: Settings / Network / Insights live in the same window.
        let windowsBefore = visibleWindows().count
        model.show(.settings)
        try await sleep(800)
        shot("07-settings")
        check("R13", "Settings opens inside the main window (no second window)", visibleWindows().count == windowsBefore && model.experience == .settings, "windows=\(visibleWindows().count)")
        check("R13", "chrome bar still first on the settings page", (ax(w, "sidebar-toggle")?.minX ?? 0) < (ax(w, "experience-switcher")?.minX ?? -1))
        // R38: switching pages is immediate — the page's header is on screen within 150 ms, and the main
        // thread's first turn after the switch is short (data fills in afterwards).
        func measureSwitch(_ e: AppModel.Experience, header: String) async throws -> (turnMs: Int, headerMs: Int) {
            let t0 = Date()
            model.show(e)
            await Task.yield()
            let turn = Int(Date().timeIntervalSince(t0) * 1000)
            var headerAt = -1
            for i in 0..<30 { try await sleep(10); if ax(w, header) != nil { headerAt = (i + 1) * 10; break } }
            return (turn, headerAt)
        }
        let toNetwork = try await measureSwitch(.network, header: "network-header")
        check("R38", "⌘2 Network shows its page at once (rows fill in)", toNetwork.headerMs >= 0 && toNetwork.headerMs <= 150 && toNetwork.turnMs < 250, "turn=\(toNetwork.turnMs)ms header=\(toNetwork.headerMs)ms connections=\(model.inbox.connections.count)")
        var arrived = -1
        for i in 0..<80 { try await sleep(100); if model.inbox.connections.count >= 12_000, !model.inbox.connectionsLoading { arrived = (i + 1) * 100; break } }
        check("R38", "Network rows (12k) arrive after the switch, within 8 s", arrived > 0, "arrivedAfter=\(arrived)ms connections=\(model.inbox.connections.count)")
        let toInsights = try await measureSwitch(.insights, header: "insights-header")
        check("R38", "⌘3 Insights shows its page at once (numbers fill in)", toInsights.headerMs >= 0 && toInsights.headerMs <= 150 && toInsights.turnMs < 250, "turn=\(toInsights.turnMs)ms header=\(toInsights.headerMs)ms")
        let toMessenger = try await measureSwitch(.messenger, header: "thread-header")
        check("R38", "⌘1 Messenger shows its page at once", toMessenger.headerMs >= 0 && toMessenger.headerMs <= 150 && toMessenger.turnMs < 250, "turn=\(toMessenger.turnMs)ms header=\(toMessenger.headerMs)ms")
        model.show(.network); try await sleep(600); shot("08-network")
        check("R13", "Network inside the main window", visibleWindows().count == windowsBefore)
        // R34: the new-message button is on the band everywhere; from another page it switches to the inbox and starts the draft.
        check("R34", "new-message button on the band while on Network", ax(w, "compose-button") != nil)
        clickProbe("compose-button", in: w)
        try await sleep(700)
        shot("08b-compose-from-network")
        check("R34", "clicking it from Network opens the inbox with a new message started", model.experience == .messenger && model.inbox.composing && ax(w, "compose-instructions") != nil, "exp=\(model.experience) composing=\(model.inbox.composing)")
        if let instr = ax(w, "compose-instructions") { check("R34b", "new-message instructions wrap instead of truncating", instr.height > 30, "height=\(Int(instr.height))") }
        model.inbox.composing = false
        // R35: insights per account with a window of time; two-line header.
        model.show(.insights); try await sleep(1500); shot("08c-insights")
        check("R35", "insights sidebar lists the account(s)", !axAll(w, "insights-account-\(model.current?.id ?? "")").isEmpty)
        check("R35", "insights range chips: all time · year · month · week · day · custom", InsightsRange.allCases.allSatisfy { ax(w, "insights-range-\($0.rawValue)") != nil })
        if let h = ax(w, "insights-header") { check("R35", "insights header is two lines (page + account)", h.height <= 40, "height=\(Int(h.height))") }
        // R35b: switching the window never blanks the page — the tiles stay and their values change.
        var tilePresent: [Bool] = []
        clickProbe("insights-range-allTime", in: w)
        for _ in 0..<20 { try await sleep(50); tilePresent.append(ax(w, "insights-tile-sent") != nil) }
        check("R35b", "switching the time window keeps the tiles on screen (no flash)", tilePresent.allSatisfy { $0 }, "present=\(tilePresent.filter { $0 }.count)/\(tilePresent.count)")
        clickProbe("insights-range-custom", in: w); try await sleep(500)
        check("R35", "custom range shows a days field", ax(w, "insights-custom-days") != nil)
        clickProbe("insights-range-month", in: w); try await sleep(300)
        model.show(.messenger); try await sleep(600)

        // --- R4: collapsing the sidebar leaves the chrome bar exactly where it is; R13b: per-page memory, Settings never collapses.
        let toggleBefore = ax(w, "sidebar-toggle"); let switcherBefore = ax(w, "experience-switcher")
        let headerBefore = ax(w, "thread-header")
        let bubblesBefore = axAll(w, "bubble-shape").map { Int($0.width.rounded()) }.sorted()
        model.toggleSidebar()
        var contentWidths: [Int] = [], bottomsCollapse: [Int] = []
        for _ in 0..<12 { try await sleep(25); contentWidths.append(Int(ax(w, "thread-bottom")?.width ?? 0)); bottomsCollapse.append(Int(ax(w, "thread-bottom")?.maxY ?? 0)) }
        try await sleep(600)
        shot("09-collapsed")
        check("R32c", "messages do not shift while the sidebar collapses", (bottomsCollapse.max() ?? 0) - (bottomsCollapse.min() ?? 0) <= 1, "bottomY=\(bottomsCollapse)")
        check("R32b", "collapsing the sidebar shifts the thread gradually", Array(Set(contentWidths)).count >= 3, "widths=\(contentWidths)")
        check("R32b", "bubbles keep their size when the sidebar collapses (only whitespace moves)", bubblesBefore == axAll(w, "bubble-shape").map { Int($0.width.rounded()) }.sorted(), "before=\(bubblesBefore.suffix(4)) after=\(axAll(w, "bubble-shape").map { Int($0.width.rounded()) }.sorted().suffix(4))")
        check("R4", "collapsed: the sidebar toggle is still visible", (ax(w, "sidebar-toggle")?.width ?? 0) > 10)
        check("R4b", "every icon button's symbol exists", IconButton.seenSymbols.allSatisfy { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }, "missing=\(IconButton.seenSymbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil })")
        check("R4", "sidebar collapses (slid out to the left)", model.isSidebarCollapsed && (ax(w, "sidebar").map { $0.maxX < 2 } ?? true) && (ax(w, "conversation-list")?.maxX ?? 0) < 2, "sidebar.maxX=\(Int(ax(w, "sidebar")?.maxX ?? 0))")
        if let t = ax(w, "sidebar-toggle"), let s = ax(w, "experience-switcher"), let t0 = toggleBefore, let s0 = switcherBefore {
            check("R4", "collapsed: toggle and switcher did not move", abs(t.minX - t0.minX) < 1 && abs(t.minY - t0.minY) < 1 && abs(s.minX - s0.minX) < 1, "toggle \(Int(t0.minX))→\(Int(t.minX)) switcher \(Int(s0.minX))→\(Int(s.minX))")
        } else { check("R4", "collapsed: chrome bar present", false) }
        if let header = ax(w, "thread-header"), let h0 = headerBefore { check("R6", "collapsed: thread header stays exactly where it was", abs(header.minX - h0.minX) < 1 && abs(header.minY - h0.minY) < 1, "header.x \(Int(h0.minX))→\(Int(header.minX))") } else { check("R6", "collapsed: thread header present", false) }
        check("R5", "collapsed: the `i` stayed put", abs((ax(w, "inspector-toggle")?.midX ?? -99) - closedX) < 2)
        model.show(.network); try await sleep(700)
        check("R13b", "Network remembers its own sidebar state (not collapsed)", !model.isSidebarCollapsed)
        model.show(.settings); try await sleep(700)
        shot("09b-settings")
        model.toggleSidebar(); try await sleep(300)
        check("R13b", "Settings never collapses the sidebar", !model.isSidebarCollapsed && !model.canCollapseSidebar)
        check("R4", "Settings: the sidebar toggle is still visible", (ax(w, "sidebar-toggle")?.width ?? 0) > 10)
        check("R34", "Settings: the new-message button is on the band", ax(w, "compose-button") != nil)
        model.show(.messenger); try await sleep(700)
        check("R13b", "Messenger comes back collapsed, as left", model.isSidebarCollapsed)
        model.toggleSidebar(); try await sleep(900)
        check("R4", "expanded again: sidebar back", !model.isSidebarCollapsed && (ax(w, "sidebar")?.width ?? 0) > 300)
        shot("10-expanded")

        // --- R31: the row hover capsule is centered on its row, icons centered in it.
        if let hoverId = ids.dropFirst(2).first(where: { fullyVisible($0) }) {
            model.inbox.rowPopover = .init(convId: hoverId, kind: .label)
            try await sleep(500)
            shot("05c-row-hover")
            // The capsule for *this* row (a synthesized click elsewhere can leave another row hovered).
            if let row = ax(w, "row-\(hoverId)"), let capsule = axAll(w, "row-actions").min(by: { abs($0.midY - row.midY) < abs($1.midY - row.midY) }) {
                let icons = axAll(w, "row-action-icon").filter { $0.midY >= capsule.minY - 1 && $0.maxY <= capsule.maxY + 1 }
                check("R31", "hover capsule is vertically centered on its row", abs(capsule.midY - row.midY) < 1.5, "capsule.midY=\(Int(capsule.midY)) row.midY=\(Int(row.midY))")
                check("R31", "hover icons are vertically centered in the capsule", icons.count == 3 && icons.allSatisfy { abs($0.midY - capsule.midY) < 1.5 }, "icons=\(icons.count)")
            } else { check("R31", "hover capsule present", false) }
            model.inbox.rowPopover = nil
            try await sleep(300)
        }

        // --- R30: sending feels solid — the bubble appears at once, the stream stays pinned to the
        // bottom at every frame, and the placeholder and its stored copy never show together.
        // A thread whose last message is yours: the previous bubble's tail must not change when the stored copy lands.
        if let conv = order.dropFirst(4).first(where: { !$0.record.isGroupThread && $0.lastMessage?.isFromMe == true }) {
            model.inbox.select(conv.record.convId, reveal: true)
            try await sleep(1200)
            let id = conv.record.convId
            var storedCounts: [Int] = []
            let text = "Harness ping \(Int(Date().timeIntervalSince1970))"
            let storedBefore = axAll(w, "bubble-stored").count
            var samples: [(ms: Int, bottomIn: Bool, outgoing: Int, stored: Int, bottomY: Int)] = []
            var lastPlaceholderFrame: CGRect?, firstStoredFrame: CGRect?, returnedAt = -1, fineTrace: [String] = []
            let t0 = Date()
            Task { _ = await model.inbox.send(text, to: id); returnedAt = Int(Date().timeIntervalSince(t0) * 1000) }
            // Fine trace around the Sending→Sent flip: every 10 ms, the lowest bubble, its caption, the composer and the bottom marker.
            Task { @MainActor in
                var fine: [String] = []
                for _ in 0..<400 {
                    try? await Task.sleep(for: .milliseconds(10))
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    let bub = axAll(w, "bubble-shape").max(by: { $0.maxY < $1.maxY })
                    let cap = ax(w, "sending-status") ?? ax(w, "sent-status")
                    let capKind = ax(w, "sending-status") != nil ? "sending" : (ax(w, "sent-status") != nil ? "sent" : "-")
                    fine.append("\(ms):b\(Int(bub?.minY ?? -1))…\(Int(bub?.maxY ?? -1)) \(capKind)\(Int(cap?.minY ?? -1))…\(Int(cap?.maxY ?? -1)) comp\(Int(ax(w, "composer")?.minY ?? -1)) bot\(Int(ax(w, "thread-bottom")?.maxY ?? -1))")
                }
                if let shots { try? fine.joined(separator: "\n").write(to: shots.appendingPathComponent("send-fine.txt"), atomically: true, encoding: .utf8) }
                fineTrace = fine
            }
            for i in 0..<80 {
                try await sleep(50)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                let b = threadAtBottom()
                let bottomY = Int(ax(w, "thread-bottom")?.maxY ?? -1)
                let out = model.inbox.outgoingMessages(id).count
                let stored = (model.inbox.messages[id] ?? []).filter { $0.body == text }.count
                samples.append((ms, b.0, out, stored, bottomY))
                storedCounts.append(axAll(w, "bubble-stored").count + axAll(w, "bubble-outgoing").count)
                if out > 0, let f = axAll(w, "bubble-shape").max(by: { $0.maxY < $1.maxY }) { lastPlaceholderFrame = f }
                if out == 0, stored > 0, firstStoredFrame == nil, let f = axAll(w, "bubble-shape").max(by: { $0.maxY < $1.maxY }) { firstStoredFrame = f }
                if [1, 4, 8, 20, 24, 30, 40].contains(i) { shot("13-send-\(String(format: "%04d", ms))ms") }
            }
            check("R30", "the stream never flashes (bubble count never drops during the send)", zip(storedCounts, storedCounts.dropFirst()).allSatisfy { $1 >= $0 }, "counts=\(storedCounts.prefix(12))…")
            check("R30", "the sent thread moves to the top of the list", model.inbox.filtered.first?.record.convId == id || model.inbox.pinnedInView.contains { $0.record.convId == id }, "top=\(model.inbox.filtered.first?.record.displayName ?? "-")")
            let appearedAt = samples.first { $0.outgoing > 0 || $0.stored > 0 }?.ms ?? -1
            check("R30", "the sent bubble appears within 150 ms", appearedAt >= 0 && appearedAt <= 150, "appeared=\(appearedAt)ms")
            let settled = samples.filter { $0.ms > 700 } // the rise-in and its final correction take ~400 ms; slack for a loaded machine
            check("R30", "the stream stays at the newest message while sending (after the rise-in)", !settled.isEmpty && settled.allSatisfy(\.bottomIn), "offFrames=\(settled.filter { !$0.bottomIn }.map(\.ms))")
            let ys = settled.map(\.bottomY)
            check("R30", "the bottom edge does not jump once settled", (ys.max() ?? 0) - (ys.min() ?? 0) <= 2, "bottomY=\(ys.min() ?? 0)…\(ys.max() ?? 0) trace=\(settled.map { "\($0.ms):\($0.bottomY)/o\($0.outgoing)s\($0.stored)" }.joined(separator: " "))")
            check("R30", "placeholder and stored copy never show together", samples.allSatisfy { !($0.outgoing > 0 && $0.stored > 0) }, "both=\(samples.filter { $0.outgoing > 0 && $0.stored > 0 }.map(\.ms))")
            check("R30", "the message ends up stored, placeholder gone", samples.last.map { $0.stored == 1 && $0.outgoing == 0 } == true && axAll(w, "bubble-stored").count == storedBefore + 1, "last=\(samples.last.map { "out=\($0.outgoing) stored=\($0.stored)" } ?? "-") bubbles \(storedBefore)→\(axAll(w, "bubble-stored").count)")
            let swappedAt = samples.first { $0.stored > 0 }?.ms ?? -1
            check("R30", "the stored copy is picked up from the store before the CLI returns (watcher path)", swappedAt > 0 && (returnedAt < 0 || swappedAt < returnedAt), "stored@\(swappedAt)ms returned@\(returnedAt)ms")
            // Every 10 ms sample from 300 ms before the flip to the end must show the same bubble/caption/bottom numbers.
            try await sleep(900)
            if let flipAt = fineTrace.firstIndex(where: { $0.contains(" sent") }) {
                let strip: (String) -> String = { String($0.split(separator: ":", maxSplits: 1).last ?? "").replacingOccurrences(of: "sending", with: "cap").replacingOccurrences(of: "sent", with: "cap") }
                let window = fineTrace[max(0, flipAt - 30)...].map(strip)
                check("R30", "nothing moves through the Sending→Sent flip (10 ms trace: bubble, caption, composer, bottom)", Set(window).count == 1, "distinct=\(Set(window).sorted().prefix(3))")
            } else { check("R30", "fine trace saw the Sent status", false, "samples=\(fineTrace.count)") }
            if let a = lastPlaceholderFrame, let b = firstStoredFrame {
                check("R30", "Sending→Sent flips in place: the bubble keeps its position and size", abs(a.minX - b.minX) < 1.5 && abs(a.minY - b.minY) < 1.5 && abs(a.width - b.width) < 1.5, "placeholder=\(Int(a.minX)),\(Int(a.minY)) \(Int(a.width))w stored=\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))w")
            } else { check("R30", "placeholder and stored frames captured", false) }
        }

        // --- R12b: two recipients in a new message make a group thread (through the CLI).
        let a = DraftRecipient(slug: "nova-example", name: "Nova Example", headline: nil, avatarURL: nil)
        let b = DraftRecipient(slug: "kit-example", name: "Kit Example", headline: nil, avatarURL: nil)
        model.inbox.startDraft(a)
        model.inbox.addDraftRecipient(b)
        try await sleep(600)
        shot("11-group-draft")
        check("R12b", "draft lists both recipients", model.inbox.draftRecipients.count == 2 && ax(w, "draft-chip-kit-example") != nil)
        let sent = await model.inbox.send("Group hello", to: a.convId)
        try await sleep(1200)
        shot("12-group-sent")
        let sel = model.inbox.selected?.record
        check("R12b", "send created a group thread and opened it", sent && sel?.isGroupThread == true && Set(["nova-example", "kit-example"]).isSubset(of: Set(sel?.members.compactMap(\.slug) ?? [])), "sent=\(sent) selected=\(sel?.displayName ?? "nil")")
        // --- R33: ⌘W closes the inbox window only; the app stays in the menu bar and reopens it.
        w.performClose(nil)
        try await sleep(800)
        check("R33", "closing the inbox leaves no visible inbox window", window() == nil, "windows=\(visibleWindows().count)")
        check("R33", "the app is still running as a menu bar item", NSApp.activationPolicy() == .accessory && AppDelegate.shared?.statusItem != nil, "policy=\(NSApp.activationPolicy().rawValue)")
        model.openInbox(convId: nil)
        try await wait("reopened window", 10) { window() != nil }
        let w2 = window()!
        w2.orderFrontRegardless()
        try await sleep(600)
        check("R33", "the status item brings the inbox back without LaunchServices", model.openInboxScene != nil && w2.isVisible && ax(w2, "sidebar-toggle") != nil)
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

    /// Click a probe (top-down frame → window base coordinates).
    static func clickProbe(_ id: String, in w: NSWindow) {
        guard let r = ax(w, id) else { return }
        clickWindowRect(CGRect(x: r.minX, y: w.frame.height - r.maxY, width: r.width, height: r.height), in: w)
    }

    /// A real click (down + up through the app's event path) at the center of a window-coordinate rect (bottom-up).
    static func clickWindowRect(_ rect: CGRect, in w: NSWindow) {
        let p = CGPoint(x: rect.midX, y: rect.midY)
        let t = ProcessInfo.processInfo.systemUptime
        if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: t, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
           let up = NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: t + 0.05, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
            w.sendEvent(down)
            w.sendEvent(up)
        }
    }

    /// A plain key press to the window's first responder (SwiftUI `onKeyPress`).
    static func sendKey(_ chars: String, to w: NSWindow) {
        let t = ProcessInfo.processInfo.systemUptime
        if let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: t, windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0),
           let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: t + 0.03, windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0) {
            w.sendEvent(down)
            w.sendEvent(up)
        }
    }
}

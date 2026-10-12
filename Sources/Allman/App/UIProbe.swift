// Layout probes for the rule checks (UIRuleChecks): a view tagged `.uiProbe("id")`
// gets that accessibility identifier and, while a check run is active, a zero-cost
// AppKit view behind it that the registry can ask for the view's *current* frame in
// window coordinates — rows inside a scrolled list, toolbar items, panels alike.
// SwiftUI only builds its accessibility tree for assistive clients, so this is what
// the in-app checks read. Nothing is installed when no run is active.

import AppKit
import SwiftUI

@MainActor
enum UIProbeRegistry {
    static let enabled = ProcessInfo.processInfo.environment["ALLMAN_UICHECK_OUT"].map { !$0.isEmpty } ?? false
    private struct Weak { weak var view: ProbeNSView? }
    private static var views: [ObjectIdentifier: Weak] = [:]

    static func register(_ v: ProbeNSView) {
        views[ObjectIdentifier(v)] = Weak(view: v)
        views = views.filter { $0.value.view != nil }
    }
    static func unregister(_ v: ProbeNSView) { views.removeValue(forKey: ObjectIdentifier(v)) }
    private static var live: [ProbeNSView] { views.values.compactMap(\.view) }

    /// Live frames for an id, window coordinates **top-down**, widest first. Only views that
    /// are in the inbox window right now count (SwiftUI also measures toolbar items in
    /// detached hosts; those never show up here). Collapsed (≤ 2pt) frames are skipped.
    static func all(_ id: String) -> [CGRect] {
        live.filter { $0.key == id }.compactMap(\.windowFrameTopDown)
            .filter { $0.width > 2 && $0.height > 0 }
            .sorted { $0.width > $1.width }
    }
    static func first(_ id: String) -> CGRect? { all(id).first }

    /// Ids (with this prefix) of probes that are in the inbox window right now.
    static func liveIds(prefix: String) -> [String] {
        live.filter { $0.key.hasPrefix(prefix) && $0.windowFrameTopDown != nil }.map(\.key)
    }

    /// Why a probe with this id is or isn't counted (diagnostics).
    static func explain(_ id: String) -> String {
        live.filter { $0.key == id }.map { v in
            "window=\(v.window.map { AppDelegate.isInbox($0) ? "inbox" : "other" } ?? "nil") hidden=\(v.isHiddenOrHasHiddenAncestor) frame=\(v.windowFrameTopDown.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-")"
        }.joined(separator: " | ")
    }

    /// Every live probe, for diagnostics.
    static var dump: [String] {
        live.compactMap { v in v.windowFrameTopDown.map { "\(v.key) \($0)" } }.sorted()
    }
}

final class ProbeNSView: NSView {
    var key = ""
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated { UIProbeRegistry.register(self) }
    }

    /// Frame in the window, top-down (y = 0 at the window's top edge), or nil when not in the inbox window.
    var windowFrameTopDown: CGRect? {
        guard let w = window, AppDelegate.isInbox(w), !isHiddenOrHasHiddenAncestor else { return nil }
        let r = convert(bounds, to: nil)
        return CGRect(x: r.minX, y: w.frame.height - r.maxY, width: r.width, height: r.height)
    }
}

private struct ProbeView: NSViewRepresentable {
    let key: String
    // Registered at creation too: a List cell can be in the window before its representable exists.
    func makeNSView(context: Context) -> ProbeNSView { let v = ProbeNSView(); v.key = key; UIProbeRegistry.register(v); return v }
    func updateNSView(_ v: ProbeNSView, context: Context) { v.key = key }
}

private struct UIProbe: ViewModifier {
    let id: String
    /// Installed even outside check runs: the view's own code reads the frame (the list's row reveal).
    let always: Bool
    func body(content: Content) -> some View {
        if always || UIProbeRegistry.enabled {
            content.accessibilityIdentifier(id).background(ProbeView(key: id))
        } else {
            content.accessibilityIdentifier(id)
        }
    }
}

extension View {
    func uiProbe(_ id: String, always: Bool = false) -> some View { modifier(UIProbe(id: id, always: always)) }
}

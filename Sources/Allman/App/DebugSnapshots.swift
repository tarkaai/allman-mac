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
            let target = named ?? rich ?? model.inbox.unread.first ?? model.inbox.snapshots.first
            model.openInbox(convId: target?.record.convId)
            try? await Task.sleep(for: .seconds(4))
            if let w = NSApp.windows.first(where: AppDelegate.isInbox) {
                capture(w, to: out.appendingPathComponent("inbox.png"))
                model.debugShowTimes = true
                try? await Task.sleep(for: .seconds(1))
                capture(w, to: out.appendingPathComponent("inbox-times.png"))
                model.debugShowTimes = false
                model.inbox.filter = .unread
                try? await Task.sleep(for: .seconds(1))
                capture(w, to: out.appendingPathComponent("inbox-unread.png"))
                model.inbox.filter = .all
                if ProcessInfo.processInfo.environment["ALLMAN_SNAPSHOT_COMPOSE"] != nil {
                    NotificationCenter.default.post(name: .allmanCompose, object: nil)
                    try? await Task.sleep(for: .seconds(6)) // local + CLI search
                    if let sheet = w.attachedSheet ?? w.sheets.first ?? NSApp.windows.first(where: { $0.isVisible && $0 !== w && $0.level == w.level && $0.frame.width < w.frame.width }) {
                        capture(sheet, to: out.appendingPathComponent("compose.png"))
                    } else {
                        capture(w, to: out.appendingPathComponent("compose.png")) // whole window incl. sheet
                    }
                }
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

            model.openSettingsWindow?()
            try? await Task.sleep(for: .seconds(2))
            if let w = NSApp.windows.first(where: { $0.title.localizedCaseInsensitiveContains("settings") && $0.isVisible }) {
                capture(w, to: out.appendingPathComponent("settings.png"))
                w.orderOut(nil)
            }

            // Attention state: what the panel looks like when the LinkedIn session is gone.
            model.engine.markNeedsLogin(reason: "LinkedIn session expired")
            panel.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(1))
            panel.setContentSize(hosting.fittingSize)
            try? await Task.sleep(for: .seconds(1))
            capture(panel, to: out.appendingPathComponent("panel-login.png"))
            NSApp.terminate(nil)
        }
    }

    private typealias WindowImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// The SDK no longer exposes CGWindowListCreateImage, but the OS still ships it;
    /// resolving it at runtime avoids a Screen Recording prompt for our own windows.
    private static let windowImage: WindowImageFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: WindowImageFn.self)
    }()

    private static func capture(_ window: NSWindow, to url: URL) {
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

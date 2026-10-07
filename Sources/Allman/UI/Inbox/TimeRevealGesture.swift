// iMessage-style timestamp reveal: a horizontal two-finger swipe over the
// thread slides every bubble left to uncover the times parked off-screen, and
// the view springs back when the gesture ends. Vertical scrolling is untouched.

import AppKit
import SwiftUI

struct TimeRevealGesture: NSViewRepresentable {
    @Binding var reveal: CGFloat
    let maxReveal: CGFloat

    func makeNSView(context: Context) -> TrackingView {
        let v = TrackingView()
        v.onScroll = { delta, ended in
            if ended {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { reveal = 0 }
            } else {
                reveal = min(max(reveal - delta, 0), maxReveal)
            }
        }
        return v
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        var onScroll: ((CGFloat, Bool) -> Void)?
        private var monitor: Any?
        private var active = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                if let m = monitor { NSEvent.removeMonitor(m) }
                monitor = nil
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let onScroll = self.onScroll else { return event }
                guard event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                let inside = self.bounds.contains(point)
                let dx = event.scrollingDeltaX
                let dy = event.scrollingDeltaY
                let horizontal = abs(dx) > abs(dy)

                if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
                    if self.active { self.active = false; onScroll(0, true) }
                    return event
                }
                if event.momentumPhase != [] { return self.active ? nil : event } // swallow horizontal momentum
                guard inside, horizontal || self.active else { return event }
                if event.phase == .began || event.phase == .changed || event.phase == .stationary || event.phase == [] {
                    if horizontal || self.active {
                        self.active = true
                        onScroll(dx, false)
                        return nil // don't let the scroll view bounce horizontally
                    }
                }
                return event
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}

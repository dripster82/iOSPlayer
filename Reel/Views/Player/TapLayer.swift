import SwiftUI
import UIKit

/// Tap, double tap and hold for the player, read from raw touches rather than gesture recognisers.
///
/// Recognisers were unreliable here: UIKit arbitrates between ours and the ones SwiftUI installs for
/// the drag and pinch gestures layered on top, and a tap sometimes lost that arbitration. Touch events
/// reach the view before any recogniser has a say, so a touch that lifts quickly without moving is a
/// tap, every time. Drags still work: once SwiftUI's drag recogniser claims the touch it cancels it
/// here, which simply means "not a tap".
struct TapLayer: UIViewRepresentable {
    var onTap: () -> Void
    /// Location in the layer's coordinate space.
    var onDoubleTap: (CGPoint, CGSize) -> Void
    var onHoldBegan: () -> Void
    var onHoldEnded: () -> Void

    func makeUIView(context: Context) -> TouchView {
        let v = TouchView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = false
        v.handlers = Handlers(onTap: onTap, onDoubleTap: onDoubleTap, onHoldBegan: onHoldBegan, onHoldEnded: onHoldEnded)
        return v
    }
    func updateUIView(_ uiView: TouchView, context: Context) {
        uiView.handlers = Handlers(onTap: onTap, onDoubleTap: onDoubleTap, onHoldBegan: onHoldBegan, onHoldEnded: onHoldEnded)
    }

    struct Handlers {
        var onTap: () -> Void
        var onDoubleTap: (CGPoint, CGSize) -> Void
        var onHoldBegan: () -> Void
        var onHoldEnded: () -> Void
    }

    final class TouchView: UIView {
        var handlers: Handlers?
        private var start: (point: CGPoint, time: TimeInterval)?
        private var moved = false
        private var holding = false
        private var holdTimer: Timer?
        private var lastTap: (point: CGPoint, time: TimeInterval)?

        private let moveTolerance: CGFloat = 12
        private let doubleTapWindow: TimeInterval = 0.35
        private let holdDelay: TimeInterval = 0.4

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            guard let t = touches.first else { return }
            start = (t.location(in: self), t.timestamp)
            moved = false
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: holdDelay, repeats: false) { [weak self] _ in
                guard let self, !self.moved, self.start != nil else { return }
                self.holding = true
                self.handlers?.onHoldBegan()
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            guard let t = touches.first, let start else { return }
            let p = t.location(in: self)
            if hypot(p.x - start.point.x, p.y - start.point.y) > moveTolerance { moved = true; holdTimer?.invalidate() }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            holdTimer?.invalidate()
            defer { start = nil }
            if holding { holding = false; handlers?.onHoldEnded(); return }
            guard let t = touches.first, let start, !moved, t.timestamp - start.time < 0.5 else { return }
            let p = t.location(in: self)
            handlers?.onTap()
            if let last = lastTap, t.timestamp - last.time < doubleTapWindow, hypot(p.x - last.point.x, p.y - last.point.y) < 40 {
                lastTap = nil
                handlers?.onDoubleTap(p, bounds.size)
            } else {
                lastTap = (p, t.timestamp)
            }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            holdTimer?.invalidate()
            if holding { holding = false; handlers?.onHoldEnded() }
            start = nil
        }
    }
}

/// The display's brightness. `UIScreen.main` does not reach the iPad's display on recent iPadOS; the
/// active window scene's screen does.
enum ScreenBrightness {
    private static var screen: UIScreen? {
        (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)?.screen
    }
    static var value: Double {
        get { Double(screen?.brightness ?? UIScreen.main.brightness) }
        set { let v = CGFloat(max(0, min(1, newValue))); if let screen { screen.brightness = v } else { UIScreen.main.brightness = v } }
    }
}

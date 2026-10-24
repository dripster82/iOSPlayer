import SwiftUI
import UIKit

/// Every player gesture on one UIKit view: tap, double tap, hold, drag and pinch.
///
/// Mixing SwiftUI gestures with a UIKit tap layer was unreliable: SwiftUI's drag and pinch recognisers
/// sat above the view and delayed or cancelled touches before it saw them, so taps dropped. With all
/// recognisers on this view, configured by us to run together and never delay touches, there is no
/// arbitration left: the single tap fires on its first lift, the double on the second, the hold after
/// 0.4 s, and a drag reports its translation from a start location.
struct GestureLayer: UIViewRepresentable {
    struct Drag { var translation: CGSize; var start: CGPoint; var size: CGSize }

    var onTap: () -> Void
    var onDoubleTap: (CGPoint, CGSize) -> Void
    var onHoldBegan: () -> Void
    var onHoldEnded: () -> Void
    var onDragChanged: (Drag) -> Void
    var onDragEnded: () -> Void
    var onPinchEnded: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let c = context.coordinator
        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped))
        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = 0.4
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinched(_:)))
        for g in [single, double, hold, pan, pinch] {
            g.cancelsTouchesInView = false
            g.delaysTouchesBegan = false
            g.delaysTouchesEnded = false
            g.delegate = c
            v.addGestureRecognizer(g)
        }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: GestureLayer
        private var dragStart: CGPoint = .zero
        init(parent: GestureLayer) { self.parent = parent }

        @objc func tapped() { parent.onTap() }
        @objc func doubleTapped(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            parent.onDoubleTap(g.location(in: v), v.bounds.size)
        }
        @objc func held(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began: parent.onHoldBegan()
            case .ended, .cancelled, .failed: parent.onHoldEnded()
            default: break
            }
        }
        @objc func panned(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            switch g.state {
            case .began: dragStart = g.location(in: v)
            case .changed:
                let t = g.translation(in: v)
                parent.onDragChanged(Drag(translation: CGSize(width: t.x, height: t.y), start: dragStart, size: v.bounds.size))
            case .ended, .cancelled, .failed: parent.onDragEnded()
            default: break
            }
        }
        @objc func pinched(_ g: UIPinchGestureRecognizer) {
            if g.state == .ended { parent.onPinchEnded(g.scale) }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        /// A drag only starts once the finger has clearly moved, so it never steals a tap.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let v = pan.view else { return true }
            let t = pan.translation(in: v)
            return hypot(t.x, t.y) > 12
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

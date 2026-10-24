import SwiftUI
import UIKit

/// Tap, double tap and hold for the player, on UIKit recognisers. SwiftUI holds a single tap back behind
/// a double-tap recogniser attached to the same view (and with `.simultaneousGesture` it stopped firing
/// at all), so taps felt dead; UIKit recognisers fire exactly as configured: the single tap at once, the
/// double on its second tap, and the hold after its delay. Drags stay in SwiftUI on top of this view.
struct TapLayer: UIViewRepresentable {
    var onTap: () -> Void
    /// Location in the layer's coordinate space.
    var onDoubleTap: (CGPoint, CGSize) -> Void
    var onHoldBegan: () -> Void
    var onHoldEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        single.numberOfTapsRequired = 1
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = 0.4
        for g in [single, double, hold] { g.cancelsTouchesInView = false; g.delegate = context.coordinator; v.addGestureRecognizer(g) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TapLayer
        init(parent: TapLayer) { self.parent = parent }

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

        // Let SwiftUI's drag recognisers and these run together.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
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

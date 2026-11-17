import SwiftUI
import UIKit
import MediaCore

/// One `UILongPressGestureRecognizer` on the window, relaying where a long press began, so that no
/// poster card needs a gesture of its own: a SwiftUI gesture on every card, like a context menu or
/// a dialog on every card, is a UIKit object per card at launch, and creating them held the main
/// thread for 15–30 s after a reboot (HANDOVER, 17 Nov 2026). Shelves listen, convert the point into
/// their own space and find the card under it from the cards' anchor preferences.
@MainActor
final class LongPressRelay: ObservableObject {
    static let shared = LongPressRelay()
    /// The latest press, in window coordinates; a fresh id for every press.
    @Published private(set) var press: (point: CGPoint, id: UUID)?
    private var firedAt: Date?
    /// True just after a long press: the finger lifting then still counts as the card's tap to
    /// SwiftUI (no cancellation reaches its hosting view), so the tap's effect is dropped instead,
    /// in the navigation path setter and the shelves' tap handlers.
    var swallowsTap: Bool { firedAt.map { Date().timeIntervalSince($0) < 1.5 } ?? false }

    fileprivate func fire(at point: CGPoint) { firedAt = Date(); press = (point, UUID()) }
}

/// Installs the recogniser once the view is in a window. One instance, in the root view.
struct LongPressRelayInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> RelayView { RelayView() }
    func updateUIView(_ uiView: RelayView, context: Context) {}

    final class RelayView: UIView, UIGestureRecognizerDelegate {
        private var recognizer: UILongPressGestureRecognizer?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, recognizer == nil else { return }
            let r = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            r.minimumPressDuration = 0.45
            // A moving finger (more than 10 points) fails it and scrolls instead.
            // SwiftUI's hosting view has recognisers of its own on every touch; without this they
            // prevent the window's recogniser from ever beginning.
            r.delegate = self
            window.addGestureRecognizer(r)
            recognizer = r
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
        @objc private func pressed(_ r: UILongPressGestureRecognizer) {
            guard r.state == .began else { return }
            LongPressRelay.shared.fire(at: r.location(in: nil))
        }
    }
}

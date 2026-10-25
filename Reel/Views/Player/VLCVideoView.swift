import SwiftUI
import Playback
import VLCKit

/// Hosts the UIView VLC renders into, and tells the engine when its size changes so Fill stays correct.
struct VLCVideoView: UIViewRepresentable {
    let engine: VLCPlaybackEngine

    /// One drawable per engine for the life of the app. VLCKit 4 attaches its video output to the
    /// drawable it had when the media opened; giving it a fresh view for every player screen left the
    /// second video playing audio into a view that no longer existed. The host view is re-parented into
    /// each new player screen instead.
    private static var hosts: [ObjectIdentifier: VLCDrawableView] = [:]

    static func host(for engine: VLCPlaybackEngine) -> VLCDrawableView {
        if let existing = hosts[ObjectIdentifier(engine)] { return existing }
        let v = VLCDrawableView()
        v.backgroundColor = .black
        v.engine = engine
        v.onLayout = { [weak engine] in engine?.drawableDidLayout() }
        engine.drawable = v
        hosts[ObjectIdentifier(engine)] = v
        return v
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let host = Self.host(for: engine)
        host.removeFromSuperview()
        host.frame = container.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(host)
        // With a TV connected the picture goes there instead; the container stays black behind the controls.
        ExternalDisplay.shared.deviceContainer = container
        ExternalDisplay.shared.attach(host)
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        // Keep the host alive (and VLC's output attached); it is re-parented by the next player screen.
        if let host = uiView.subviews.first { ExternalDisplay.shared.release(host) }
        uiView.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// A plain UIView is a valid VLC drawable; conforming to `VLCPictureInPictureDrawable` as well makes
/// VLCKit 4 create a Picture in Picture controller for the video output and hand it back through
/// `pictureInPictureReady`. The engine owns that controller and the playback controls behind it.
final class VLCDrawableView: UIView, VLCPictureInPictureDrawable {
    weak var engine: VLCPlaybackEngine?
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        // VLCKit 4 inserts its rendering view at attach time without autoresizing, so on rotation the
        // picture kept its old size: zoomed and cropped in portrait, off-screen in landscape.
        for sub in subviews where sub.frame != bounds { sub.frame = bounds }
        onLayout?()
    }

    // MARK: VLCPictureInPictureDrawable

    // The header has no nullability annotations, hence the implicitly unwrapped types.
    func mediaController() -> (any VLCPictureInPictureMediaControlling)! {
        engine?.pictureInPictureMediaController
    }

    func pictureInPictureReady() -> (((any VLCPictureInPictureWindowControlling)?) -> Void)! {
        { [weak self] controller in
            guard let controller else { return }
            Task { @MainActor in self?.engine?.pictureInPictureDidBecomeAvailable(controller) }
        }
    }
}

import SwiftUI
import Playback
import VLCKit

/// Hosts the UIView VLC renders into, and tells the engine when its size changes so Fill stays correct.
struct VLCVideoView: UIViewRepresentable {
    let engine: VLCPlaybackEngine
    func makeUIView(context: Context) -> VLCDrawableView {
        let v = VLCDrawableView()
        v.backgroundColor = .black
        v.engine = engine
        v.onLayout = { [weak engine] in engine?.drawableDidLayout() }
        engine.drawable = v
        return v
    }
    func updateUIView(_ uiView: VLCDrawableView, context: Context) {}
}

/// A plain UIView is a valid VLC drawable; conforming to `VLCPictureInPictureDrawable` as well makes
/// VLCKit 4 create a Picture in Picture controller for the video output and hand it back through
/// `pictureInPictureReady`. The engine owns that controller and the playback controls behind it.
final class VLCDrawableView: UIView, VLCPictureInPictureDrawable {
    weak var engine: VLCPlaybackEngine?
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
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

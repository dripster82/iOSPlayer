import SwiftUI
import Playback

/// Hosts the UIView VLC renders into, and tells the engine when its size changes so Fill stays correct.
struct VLCVideoView: UIViewRepresentable {
    let engine: VLCPlaybackEngine
    func makeUIView(context: Context) -> VLCDrawableView {
        let v = VLCDrawableView()
        v.backgroundColor = .black
        v.onLayout = { [weak engine] in engine?.drawableDidLayout() }
        engine.drawable = v
        return v
    }
    func updateUIView(_ uiView: VLCDrawableView, context: Context) {}
}

final class VLCDrawableView: UIView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

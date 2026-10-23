import SwiftUI
import Playback
/// Hosts the UIView VLC renders into.
struct VLCVideoView: UIViewRepresentable {
    let engine: VLCPlaybackEngine
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        engine.drawable = v
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

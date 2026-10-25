import UIKit
import SwiftUI
import Playback
import MediaCore

/// The TV, when the iPad or iPhone is mirrored to it over AirPlay. iOS gives the app its own window
/// on the external screen; Reel moves VLC's drawable into it so the picture fills the TV at the TV's
/// own aspect ratio, while the device keeps the controls. Mirroring itself can only be started by the
/// user from Control Centre; iOS offers no API for it.
@MainActor
final class ExternalDisplay: ObservableObject {
    static let shared = ExternalDisplay()

    @Published private(set) var isConnected = false
    /// Fills the TV window; VLC's host view is parented here while connected.
    let canvas: UIView = {
        let v = UIView()
        v.backgroundColor = .black
        return v
    }()
    private var window: UIWindow?
    /// Where the host view goes back to when the TV disconnects.
    weak var deviceContainer: UIView?
    private weak var host: UIView?

    func connected(scene: UIWindowScene) {
        let w = UIWindow(windowScene: scene)
        let vc = UIViewController()
        vc.view.backgroundColor = .black
        canvas.frame = vc.view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.view.addSubview(canvas)
        w.rootViewController = vc
        w.isHidden = false
        window = w
        isConnected = true
        Diagnostics.log("display", "external screen connected: \(Int(scene.screen.bounds.width))×\(Int(scene.screen.bounds.height)) pt")
        if let host { attach(host) }
    }

    func disconnected() {
        isConnected = false
        window?.isHidden = true
        window = nil
        if let host { giveBack(host) }
        Diagnostics.log("display", "external screen disconnected")
    }

    /// Puts VLC's drawable on the TV (now, if a TV is connected; otherwise as soon as one is).
    func attach(_ host: UIView) {
        self.host = host
        guard isConnected else { return }
        host.removeFromSuperview()
        host.frame = canvas.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.addSubview(host)
        host.setNeedsLayout(); host.layoutIfNeeded()
    }

    /// The player closed: the drawable returns to the device so the next play starts there.
    func release(_ host: UIView) {
        if self.host === host { giveBack(host); self.host = nil }
    }

    private func giveBack(_ host: UIView) {
        guard let container = deviceContainer else { host.removeFromSuperview(); return }
        host.removeFromSuperview()
        host.frame = container.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(host)
        host.setNeedsLayout(); host.layoutIfNeeded()
    }
}

/// UIKit calls this for the external-display scene role (see AppDelegate).
final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        Task { @MainActor in ExternalDisplay.shared.connected(scene: ws) }
    }
    func sceneDidDisconnect(_ scene: UIScene) {
        Task { @MainActor in ExternalDisplay.shared.disconnected() }
    }
}

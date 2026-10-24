import UIKit

/// Registers for the silent CloudKit pushes that wake the sync engine when another device writes.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let remoteNotification = Notification.Name("reel.remoteNotification")

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        NotificationCenter.default.post(name: Self.remoteNotification, object: nil)
        // Give the sync engine a moment to fetch before iOS suspends us again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { completionHandler(.newData) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Not fatal: the app still fetches on foreground and after its own writes.
    }
}

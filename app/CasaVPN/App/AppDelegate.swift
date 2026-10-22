import UIKit
import UserNotifications

/// Receives the APNs token and the taps on notifications. Everything of substance lives in `AppModel`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppModel.shared.didRegisterForPush(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppModel.shared.didFailToRegisterForPush(error)
    }

    // A push that arrives while the app is open still shows as a banner, and refreshes the history.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await MainActor.run { AppModel.shared.pushArrivedInForeground() }
        return [.banner, .list, .sound]
    }

    // A tap opens the alert named by `alertId` in the payload (docs/APP.md, "Push").
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let alertId = response.notification.request.content.userInfo["alertId"] as? String
        await MainActor.run { AppModel.shared.openAlert(id: alertId) }
    }
}

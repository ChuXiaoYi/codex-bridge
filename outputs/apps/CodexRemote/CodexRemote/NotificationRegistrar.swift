import SwiftUI
import UIKit
import UserNotifications

enum DeviceTokenNotification {
    static let didUpdate = Notification.Name("CodexRemoteDeviceTokenDidUpdate")
    static let tokenKey = "token"
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(
            name: DeviceTokenNotification.didUpdate,
            object: nil,
            userInfo: [DeviceTokenNotification.tokenKey: token]
        )
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationCenter.default.post(
            name: DeviceTokenNotification.didUpdate,
            object: nil,
            userInfo: [DeviceTokenNotification.tokenKey: "error: \(error.localizedDescription)"]
        )
    }
}

@MainActor
final class NotificationRegistrar: ObservableObject {
    @Published var status = "Notifications not enabled"

    private var didInstallTokenObserver = false

    func enable(using settings: RelaySettings) async {
        installTokenObserver(using: settings)

        do {
            let center = UNUserNotificationCenter.current()
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                status = "Notification permission denied"
                return
            }

            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
                status = "Registering with APNs"
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func installTokenObserver(using settings: RelaySettings) {
        guard !didInstallTokenObserver else { return }
        didInstallTokenObserver = true
        NotificationCenter.default.addObserver(
            forName: DeviceTokenNotification.didUpdate,
            object: nil,
            queue: .main
        ) { notification in
            guard let token = notification.userInfo?[DeviceTokenNotification.tokenKey] as? String,
                  !token.hasPrefix("error:") else {
                let message = notification.userInfo?[DeviceTokenNotification.tokenKey] as? String ?? "APNs registration failed"
                Task { @MainActor in
                    self.status = message
                }
                return
            }
            Task { @MainActor in
                settings.lastDeviceToken = token
                self.status = "Device token ready"
                guard let url = settings.normalizedRelayURL else { return }
                do {
                    try await RelayAPI(baseURL: url, clientToken: settings.clientToken)
                        .registerDevice(token: token, platform: "ios")
                } catch {
                    self.status = error.localizedDescription
                }
            }
        }
    }
}

import SwiftUI

@main
struct CodexRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = RelaySettings()
    @StateObject private var threadsStore = ThreadsStore()
    @StateObject private var notificationRegistrar = NotificationRegistrar()
    @StateObject private var eventStreamStore = EventStreamStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(threadsStore)
                .environmentObject(notificationRegistrar)
                .environmentObject(eventStreamStore)
        }
    }
}

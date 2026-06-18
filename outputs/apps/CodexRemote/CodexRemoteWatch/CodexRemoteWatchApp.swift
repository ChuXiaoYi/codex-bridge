import SwiftUI

@main
struct CodexRemoteWatchApp: App {
    @StateObject private var store = WatchRemoteStore()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(store)
        }
    }
}

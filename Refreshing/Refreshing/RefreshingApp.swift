import SwiftUI

@main
struct RefreshingApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra("Refreshing", systemImage: "display") {
            MenuBarView(state: state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enable overlay only after launch is complete and display has settled
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            AppState.shared.enableOverlay()
        }
    }
}

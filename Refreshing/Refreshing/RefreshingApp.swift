import SwiftUI

@main
struct RefreshingApp: App {
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra("Refreshing", systemImage: "display") {
            MenuBarView(state: state)
        }
    }
}

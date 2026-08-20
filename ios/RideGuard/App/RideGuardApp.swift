import SwiftUI
import RideGuardCore

@main
struct RideGuardApp: App {
    /// One `AppState` for the process, created once. The share extension does
    /// NOT get this object — it is a separate process and builds its own
    /// stores from the App Group. The shared file is the contract between
    /// them, not shared memory.
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                // Verdict colours are the whole point of the card, and driving
                // at night with the phone in a mount is the normal case, so
                // both appearances have to work. Neither is forced.
                .tint(.blue)
        }
    }
}

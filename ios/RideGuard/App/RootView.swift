import SwiftUI
import RideGuardCore

/// Onboarding until the car is configured, three tabs afterwards.
///
/// Quick is first and is the default tab because it is the only screen a
/// driver opens under time pressure. History and Settings are things you look
/// at parked.
struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if state.settings.hasCompletedOnboarding {
                TabView {
                    QuickEntryView()
                        .tabItem { Label("Quick", systemImage: "bolt.fill") }
                    HistoryView()
                        .tabItem { Label("History", systemImage: "list.bullet") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                }
            } else {
                OnboardingFlow()
                    .transition(.opacity)
            }
        }
        .animation(.default, value: state.settings.hasCompletedOnboarding)
        .onChange(of: scenePhase) { _, phase in
            // The share extension is a separate process writing the same
            // history file while this one is suspended. Without this reload,
            // an offer the driver analysed from the share sheet would never
            // appear in the list.
            if phase == .active { state.reloadFromDisk() }
        }
    }
}

#Preview {
    RootView().environmentObject(AppState())
}

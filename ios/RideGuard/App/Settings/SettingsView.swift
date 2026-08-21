import SwiftUI
import RideGuardCore

/// Thresholds, commission, and the honest note about what iOS will not let
/// this app do.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        VehicleSetupView(vehicle: $state.settings.vehicle)
                            .navigationTitle("Vehicle")
                    } label: {
                        LabeledContent(state.settings.vehicle.label) {
                            Text("\(NumberParsing.formatRate(state.settings.vehicle.totalCostPerKm)) \(state.settings.vehicle.currency)/km")
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("Vehicle")
                } footer: {
                    Text("\(state.settings.vehicle.fuelType.displayName) · \(NumberParsing.formatRate(state.settings.vehicle.consumptionPer100km)) \(state.settings.vehicle.fuelType.consumptionLabel)")
                }

                thresholdsSection
                platformsSection

                Section {
                    Picker("Usual platform", selection: $state.settings.defaultPlatform) {
                        ForEach(Platform.selectable, id: \.self) { Text($0.displayName).tag($0) }
                    }
                } footer: {
                    Text("The starting point on the Quick tab. The live HUD does not use it — it reads which app the offer came from, and says nothing when it cannot tell.")
                }

                lockScreenSection
                capabilitiesSection
                updatesSection
            }
            .navigationTitle("Settings")
            .keyboardDoneBar()
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: - Thresholds

    private var thresholdsSection: some View {
        Section {
            DecimalTextField(
                title: "Minimum net per hour",
                value: $state.settings.thresholds.minNetPerHour,
                unit: "\(currency)/h"
            )
            DecimalTextField(
                title: "Minimum net per km",
                value: $state.settings.thresholds.minNetPerKm,
                unit: "\(currency)/km"
            )
            DecimalTextField(
                title: "Maximum pickup ratio",
                value: $state.settings.thresholds.maxDeadheadRatio,
                unit: "×"
            )
            DecimalTextField(
                title: "Minimum net per ride",
                value: $state.settings.thresholds.minNetTotal,
                unit: currency
            )
        } header: {
            Text("Your targets")
        } footer: {
            // Explaining the deadhead ratio in words, because it is the one
            // threshold drivers have no intuition for until they have lost a
            // day to it.
            Text("A pickup ratio of 1.0 means you drive as far to collect the passenger as you are paid to carry them. Anything above about 0.8 deserves suspicion. Miss one target and an offer is marginal; miss two and it is bad.")
        }
    }

    private var currency: String { state.settings.vehicle.currency }

    // MARK: - Platforms

    /// One toggle per platform and no commission field anywhere.
    ///
    /// Both Romanian driver apps print the driver's own take on the card —
    /// Bolt says `11,62 lei (NET, taxe incluse)`, Uber says `Câștig net (fără
    /// comisionul Uber)`. A commission slider here would be an invitation to
    /// subtract a second time, and a driver who set it to 20% would see every
    /// offer a fifth worse than reality with nothing on screen to reveal it.
    private var platformsSection: some View {
        ForEach(Platform.selectable, id: \.self) { platform in
            Section {
                Toggle("Fare shown is already net", isOn: fareIsNet(platform))
            } header: {
                Text(platform.displayName)
            } footer: {
                Text(footerText(for: platform))
            }
        }
    }

    private func footerText(for platform: Platform) -> String {
        if fareIsNet(platform).wrappedValue {
            return "\(platform.displayName) in Romania shows what you keep — the card says so in words. RideGuard subtracts nothing from it but fuel. Leave this on unless a real weekly statement says otherwise."
        }
        return "Set to treat the \(platform.displayName) fare as gross. RideGuard has no commission rate to apply, so nothing will actually be deducted — if your \(platform.displayName) really does show a gross fare, the numbers here will read better than reality."
    }

    private func fareIsNet(_ platform: Platform) -> Binding<Bool> {
        Binding(
            get: { state.settings.fareIsNet(for: platform) },
            set: { state.settings.setFareIsNet($0, for: platform) }
        )
    }

    // MARK: - Lock Screen

    /// Off by default and hidden entirely where the OS cannot do it, because a
    /// toggle that silently does nothing is worse than no toggle.
    @ViewBuilder
    private var lockScreenSection: some View {
        if LiveActivityController.isSupported {
            Section {
                Toggle("Keep the last verdict on the Lock Screen", isOn: $state.settings.liveActivityEnabled)
                if state.settings.liveActivityEnabled && !LiveActivityController.isAvailable {
                    Label(
                        "Live Activities are switched off for RideGuard in iOS Settings → RideGuard, so nothing will appear.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            } header: {
                Text("Lock Screen")
            } footer: {
                Text("After you check an offer, the verdict stays on the Lock Screen and in the Dynamic Island for ten minutes. It is the closest iPhone gets to the floating bubble on Android — but it can only show an offer you already checked, never one that just arrived.")
            }
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        Section {
            NavigationLink {
                UpdateView()
            } label: {
                LabeledContent("Updates") {
                    Text(AppVersion.current().version)
                }
            }
        } footer: {
            Text("RideGuard updates itself from GitHub rather than the App Store. It never installs anything without asking.")
        }
    }

    // MARK: - Capabilities

    /// What the app can and cannot do, so the driver reads it here rather than
    /// working it out mid-shift. Every limit named is a hard iOS one, not a
    /// roadmap item — see `docs/ios-platform-limits.md`.
    private var capabilitiesSection: some View {
        Section {
            Label("Live HUD — start it on the Live HUD tab, then drive", systemImage: "pip.fill")
            Label("Type the numbers on the Quick tab — no setup, always works", systemImage: "keyboard")
            Label("Everything runs on your phone. Nothing is uploaded.", systemImage: "lock")
            if !Persistence.isAppGroupAvailable {
                Label("App Group unavailable — the screen reader cannot see your settings in this build, so its verdicts would use defaults.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("How to use it")
        } footer: {
            Text("The live HUD reads the offer card from a screen broadcast you start, and shows the verdict in a Picture-in-Picture window — the only kind iOS lets float over another app. Both have to be started by hand each shift, because iOS gives that decision to you and no app can take it. When the HUD is not running, the Quick tab always is.")
        }
    }
}

#Preview {
    SettingsView().environmentObject(AppState())
}

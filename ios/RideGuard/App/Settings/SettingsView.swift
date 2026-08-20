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
                    Text("Used as the starting point on the Quick tab, and as the tie-break when a shared screenshot does not say which app it came from.")
                }

                capabilitiesSection
            }
            .navigationTitle("Settings")
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

    private var platformsSection: some View {
        ForEach(Platform.selectable, id: \.self) { platform in
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Commission") {
                        Text("\(Int((commission(platform).wrappedValue * 100).rounded()))%")
                            .monospacedDigit()
                    }
                    Slider(value: commission(platform), in: 0...0.5, step: 0.005)
                }
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
            return "\(platform.displayName) is set to show the amount you keep. RideGuard reconstructs the gross for the breakdown, but takes no further commission off it."
        }
        return "\(platform.displayName) is set to show the fare before commission. RideGuard subtracts \(Int((commission(platform).wrappedValue * 100).rounded()))% before costs. Check this against a real weekly statement — getting it wrong is quietly worth a fifth of your earnings."
    }

    private func commission(_ platform: Platform) -> Binding<Double> {
        Binding(
            get: { state.settings.commissionRate(for: platform) },
            set: { state.settings.setCommissionRate($0, for: platform) }
        )
    }

    private func fareIsNet(_ platform: Platform) -> Binding<Bool> {
        Binding(
            get: { state.settings.fareIsNet(for: platform) },
            set: { state.settings.setFareIsNet($0, for: platform) }
        )
    }

    // MARK: - Capabilities

    /// Better the driver reads this here than files a one-star review asking
    /// where the floating bubble is. Every word of it is a hard iOS limit, not
    /// a roadmap item — see `docs/ios-platform-limits.md`.
    private var capabilitiesSection: some View {
        Section {
            Label("Share a screenshot of an offer into RideGuard for an instant verdict", systemImage: "square.and.arrow.up")
            Label("Type the numbers on the Quick tab", systemImage: "keyboard")
            Label("Everything runs on your phone. Nothing is uploaded.", systemImage: "lock")
            if !Persistence.isAppGroupAvailable {
                Label("App Group unavailable — the share extension cannot see your settings in this build.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("How to use it")
        } footer: {
            Text("iOS does not let any app read another app's screen or draw over it. The Android version watches the Bolt and Uber driver apps directly; on iPhone that is not something Apple permits, so RideGuard works from a screenshot you share or numbers you type. Nothing else can legitimately be built here.")
        }
    }
}

#Preview {
    SettingsView().environmentObject(AppState())
}

import SwiftUI
import RideGuardCore

/// First run. Four screens, and the first one is an apology.
///
/// A driver who installs this after using the Android version arrives
/// expecting a bubble that floats over Bolt. Telling them up front what iOS
/// permits — and immediately showing them the two things that DO work — is
/// better than letting them hunt through settings for a permission that does
/// not exist.
struct OnboardingFlow: View {
    @EnvironmentObject private var state: AppState
    @State private var step: Step = .welcome

    private enum Step: Int, CaseIterable {
        case welcome, vehicle, targets, ready
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                welcome.tag(Step.welcome)
                vehicle.tag(Step.vehicle)
                targets.tag(Step.targets)
                ready.tag(Step.ready)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            footer
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Steps

    private var welcome: some View {
        StepScaffold(
            symbol: "steeringwheel",
            title: "What is actually left of that fare?",
            blurb: "A 30 lei offer with a 9 km pickup is worth less than a 20 lei offer at your door. RideGuard does that arithmetic in the seconds you have to decide."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                bullet("square.and.arrow.up", "Share a screenshot", "Screenshot the offer, tap Share, pick RideGuard. It reads the card on-device and gives you the verdict.")
                bullet("keyboard", "Or type five numbers", "Fare, pickup km and minutes, trip km and minutes.")
                bullet("iphone.slash", "No floating bubble on iPhone", "iOS does not let any app read another app's screen or draw over it. The Android version can; this one cannot, and no update will change that.")
            }
        }
    }

    private var vehicle: some View {
        StepScaffold(
            symbol: "fuelpump",
            title: "What does your car cost to run?",
            blurb: "Two numbers turn a fare into a real answer. Everything else has a sensible default."
        ) {
            VehicleSetupView(vehicle: $state.settings.vehicle)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 420)
        }
    }

    private var targets: some View {
        StepScaffold(
            symbol: "target",
            title: "What is worth your time?",
            blurb: "Miss one target and an offer is marginal. Miss two and it is bad. Start modest — raise the bar after a week of history."
        ) {
            Form {
                DecimalTextField(
                    title: "Minimum net per hour",
                    value: $state.settings.thresholds.minNetPerHour,
                    unit: "\(state.settings.vehicle.currency)/h"
                )
                DecimalTextField(
                    title: "Minimum net per km",
                    value: $state.settings.thresholds.minNetPerKm,
                    unit: "\(state.settings.vehicle.currency)/km"
                )
                Picker("Usual platform", selection: $state.settings.defaultPlatform) {
                    ForEach(Platform.selectable, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            .scrollContentBackground(.hidden)
            .frame(minHeight: 240)
        }
    }

    private var ready: some View {
        StepScaffold(
            symbol: "checkmark.seal",
            title: "Ready",
            blurb: "Every kilometre on your car costs \(NumberParsing.formatRate(state.settings.vehicle.totalCostPerKm)) \(state.settings.vehicle.currency) — and RideGuard charges that on the pickup leg too, which is where the money quietly goes."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                bullet("hand.tap", "Next offer you get", "Screenshot it, share it here, or type it in.")
                bullet("chart.line.uptrend.xyaxis", "Mark what you took", "After a week the totals tell you whether your targets are set anywhere near reality.")
                bullet("lock", "Nothing leaves the phone", "Text recognition runs on-device and the app has no network code at all.")
            }
        }
    }

    // MARK: - Chrome

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { advance(-1) }
                    .buttonStyle(.bordered)
            }
            Spacer()
            Button(step == .ready ? "Start" : "Continue") {
                if step == .ready {
                    state.completeOnboarding()
                } else {
                    advance(1)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(step == .vehicle && !state.settings.vehicle.isPlausible)
        }
        .controlSize(.large)
        .padding()
        .background(.bar)
    }

    private func advance(_ delta: Int) {
        let next = step.rawValue + delta
        guard let target = Step(rawValue: next) else { return }
        withAnimation { step = target }
    }

    private func bullet(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct StepScaffold<Content: View>: View {
    let symbol: String
    let title: String
    let blurb: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.title.weight(.bold))
                Text(blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                content
            }
            .padding(24)
            .padding(.bottom, 40)
        }
    }
}

#Preview {
    OnboardingFlow().environmentObject(AppState())
}

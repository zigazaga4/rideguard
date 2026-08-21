import SwiftUI
import RideGuardCore

/// First run. Five screens, and the middle one is the only one that matters.
///
/// The live HUD works — but only after the driver has done two things by hand
/// that no app is allowed to do for him: start a screen broadcast, and start
/// the floating window. A driver who does not know that will put the phone in
/// the mount, open Bolt, see nothing, and conclude the app is broken. So the
/// tutorial is not an optional extra here; it IS the setup.
struct OnboardingFlow: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var keyboard = KeyboardObserver()
    @State private var step: Step = .welcome

    private enum Step: Int, CaseIterable {
        case welcome, vehicle, targets, howItWorks, ready
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                welcome.tag(Step.welcome)
                vehicle.tag(Step.vehicle)
                targets.tag(Step.targets)
                howItWorks.tag(Step.howItWorks)
                ready.tag(Step.ready)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            // The footer gets out of the way while typing. Left in place,
            // SwiftUI's keyboard avoidance lifts it to sit ON TOP of the
            // keyboard — Back and Continue hovering over the number pad, eating
            // the strip of screen where the field being edited should be. It is
            // also useless there: nobody wants Continue mid-number. Done on the
            // keyboard bar brings it straight back.
            if !keyboard.isVisible {
                footer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.22), value: keyboard.isVisible)
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
                bullet("pip.fill", "A verdict that floats over Bolt", "RideGuard reads the offer card as it appears and shows what the ride is really worth in a small window on top of the driver app. It needs two taps from you to start — the next screens show you exactly which.")
                bullet("keyboard", "Or type five numbers", "Fare, pickup km and minutes, trip km and minutes. Two seconds, one thumb, no setup at all. This is the fallback whenever the HUD is not running.")
                bullet("lock", "Nothing leaves the phone", "The card is read on the device and thrown away. The only thing the app ever fetches is its own update file.")
            }
        }
    }

    private var vehicle: some View {
        // Rendered as its own Form rather than inside `StepScaffold`, so this
        // page has exactly one scroll view. See `VehicleSetupView.header`.
        VehicleSetupView(
            vehicle: $state.settings.vehicle,
            header: AnyView(
                stepHeader(
                    symbol: "fuelpump",
                    title: "What does your car cost to run?",
                    blurb: "Two numbers turn a fare into a real answer: what your car drinks, and what that costs. Everything else has a sensible default."
                )
            )
        )
        .scrollContentBackground(.hidden)
    }

    private var targets: some View {
        Form {
            Section {
                stepHeader(
                    symbol: "target",
                    title: "What is worth your time?",
                    blurb: "Miss one target and an offer is semi-profitable. Miss two and it is not profitable. Start modest — raise the bar after a week of history."
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
            .listRowBackground(Color.clear)

            Section {
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
            } footer: {
                Text("These are what the words are measured against. An offer that clears both is Profitable.")
            }
        }
        .scrollContentBackground(.hidden)
        .keyboardDoneBar()
        .scrollDismissesKeyboard(.interactively)
    }

    /// The tutorial. Two manual steps, in the order they have to happen.
    private var howItWorks: some View {
        StepScaffold(
            symbol: "pip.fill",
            title: "Two taps, every shift",
            blurb: "iOS will not let any app read the screen or float a window without you saying so each time. It is two taps, and they must be in this order."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                numberedStep(
                    "1",
                    "Start the screen broadcast",
                    "On the Live HUD tab, tap the broadcast button, choose RideGuard, then Start Broadcast. A red indicator stays on your screen while it runs — that is iOS, not us."
                )
                numberedStep(
                    "2",
                    "Start the HUD",
                    "Tap Start the HUD on the same tab. A small window appears; switch to Bolt or Uber and it stays floating on top."
                )
                Divider()
                bullet("arrow.clockwise", "After a phone call, or a restart", "Both stop. Do the same two taps again — the Live HUD tab tells you which one is off.")
                bullet("hand.draw", "Drag it where you like", "It is a Picture-in-Picture window, so iOS decides where it snaps. Tapping it does nothing, on purpose: it must never eat your Accept tap.")
            }
        }
    }

    private var ready: some View {
        StepScaffold(
            symbol: "checkmark.seal",
            title: "Ready",
            blurb: "Every kilometre on your car costs \(NumberParsing.formatRate(state.settings.vehicle.totalCostPerKm)) \(state.settings.vehicle.currency) in fuel — and RideGuard charges that on the pickup leg too, which is where the money quietly goes."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                bullet("pip.fill", "Start on the Live HUD tab", "The two taps from the last screen. Do them before you go on shift, not during one.")
                bullet("chart.line.uptrend.xyaxis", "Mark what you took", "After a week the totals tell you whether your targets are set anywhere near reality.")
                bullet("exclamationmark.triangle", "It advises, you decide", "RideGuard only does the arithmetic. Whether a ride is worth taking is still your call.")
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

    /// The heading a `StepScaffold` draws, extracted so the two `Form`-based
    /// pages can render exactly the same thing as their first row.
    private func stepHeader(symbol: String, title: String, blurb: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title2.weight(.bold))
            Text(blurb)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberedStep(_ number: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.footnote).foregroundStyle(.secondary)
            }
        }
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

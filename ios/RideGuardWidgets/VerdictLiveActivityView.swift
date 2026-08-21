import SwiftUI
import WidgetKit
import RideGuardCore

#if canImport(ActivityKit)
import ActivityKit

//  The Lock Screen and Dynamic Island rendering of the last verdict.
//
//  Deliberately not a copy of `VerdictCardView`: the Lock Screen is read at
//  arm's length, in a car, at a glance, so it carries the verdict word, the
//  net, and the per-km — and nothing else. Everything the driver might want to
//  study is in the app.

@available(iOS 16.2, *)
struct VerdictLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VerdictActivityAttributes.self) { context in
            lockScreen(context)
                // Tinting the whole surface would fight the driver's wallpaper
                // and the system's own Lock Screen contrast rules; the badge
                // carries the colour instead.
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    badge(context.state.verdict)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(context.state.netText)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                        Text("you keep")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // The units already say "per km" and "per hour". What the
                    // numbers do NOT say on their own is that they are what is
                    // left after fuel rather than what the platform advertised,
                    // so that is the word worth spending space on.
                    HStack(spacing: 6) {
                        Text("after fuel")
                        Text(context.state.perKmText)
                        if let perHour = context.state.perHourText {
                            Text("·")
                            Text(perHour)
                        }
                        Spacer()
                        Text(context.attributes.platformName)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: symbol(context.state.verdict))
                    .foregroundStyle(tint(context.state.verdict))
            } compactTrailing: {
                Text(context.state.netText)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: symbol(context.state.verdict))
                    .foregroundStyle(tint(context.state.verdict))
            }
        }
    }

    private func lockScreen(_ context: ActivityViewContext<VerdictActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                badge(context.state.verdict)
                Spacer()
                Text(context.attributes.platformName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(context.state.verdict.statusDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(context.state.netText)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                // "net" is jargon on a lock screen. Say what the number is.
                Text("in your pocket, after fuel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("after fuel")
                Text(context.state.perKmText)
                if let perHour = context.state.perHourText {
                    Text("·")
                    Text(perHour)
                }
                Text("·")
                Text(context.state.distanceText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private func badge(_ verdict: Verdict) -> some View {
        Label(verdict.statusLabel, systemImage: symbol(verdict))
            .font(.caption.weight(.heavy))
            .foregroundStyle(tint(verdict))
    }

    // `tint` and `symbol` stay duplicated from the app's `Verdict` extension:
    // the widget extension has a hard memory budget and pulling in the app's
    // SwiftUI layer to reach two switch statements is a bad trade. The WORDS
    // are a different matter — those now come from `Verdict.statusLabel` in
    // Core, which this target already links, because a driver seeing one word
    // on the Dynamic Island and a different one in the app is a real bug and
    // that is exactly what the duplicated copy caused.
    private func tint(_ verdict: Verdict) -> Color {
        switch verdict {
        case .good: return .green
        case .marginal: return .orange
        case .bad: return .red
        case .unknown: return .gray
        }
    }

    private func symbol(_ verdict: Verdict) -> String {
        switch verdict {
        case .good: return "checkmark.circle.fill"
        case .marginal: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

#endif

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
                    Text(context.state.netText)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(context.state.netText)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("net")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
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
        Label(label(verdict), systemImage: symbol(verdict))
            .font(.caption.weight(.heavy))
            .foregroundStyle(tint(verdict))
    }

    // Duplicated from the app's `Verdict` extension rather than shared: the
    // widget extension has a hard memory budget and pulling in the app's
    // SwiftUI layer to reach three switch statements is a bad trade.
    private func tint(_ verdict: Verdict) -> Color {
        switch verdict {
        case .good: return .green
        case .marginal: return .orange
        case .bad: return .red
        case .unknown: return .gray
        }
    }

    private func label(_ verdict: Verdict) -> String {
        switch verdict {
        case .good: return "TAKE IT"
        case .marginal: return "MARGINAL"
        case .bad: return "SKIP IT"
        case .unknown: return "UNCLEAR"
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

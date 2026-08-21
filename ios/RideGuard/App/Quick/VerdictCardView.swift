import SwiftUI
import RideGuardCore

// The one screen that matters: the driver typed some numbers and wants to know
// whether the ride is worth taking.

extension Verdict {
    /// Colour is the fast channel, but never the only one: the label and the
    /// symbol carry the same information for a colour-blind driver, and for a
    /// phone in a windscreen mount in direct sun where green and amber are
    /// hard to tell apart.
    var tint: Color {
        switch self {
        case .good: return .green
        case .marginal: return .orange
        case .bad: return .red
        case .unknown: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .marginal: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

struct VerdictCardView: View {
    let economics: OfferEconomics

    private var currency: String { economics.currency }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            // The headline is NET, not the fare. The whole app exists because
            // the fare is the number the platforms show and the net is the
            // number the driver actually lives on.
            VStack(alignment: .leading, spacing: 2) {
                Text(NumberParsing.formatMoney(economics.net, currency: currency))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(economics.isLossMaking ? Color.red : Color.primary)
                    .contentTransition(.numericText())
                Text("in your pocket, after fuel")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            rates
            Divider()
            breakdown

            if !economics.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(economics.reasons.enumerated()), id: \.offset) { _, reason in
                        Label(reason, systemImage: "circle.fill")
                            .labelStyle(BulletLabelStyle())
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if economics.offer.parseConfidence < 0.85 {
                lowConfidenceNote
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(economics.verdict.tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(economics.verdict.tint.opacity(0.45), lineWidth: 2)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: economics.verdict.symbol)
                .font(.title2)
                .foregroundStyle(economics.verdict.tint)
            // The word first, then one line saying what it is based on. A
            // driver who only ever reads the word still gets the right answer;
            // one who wants to know why does not have to work it out from the
            // breakdown below.
            VStack(alignment: .leading, spacing: 1) {
                Text(economics.verdict.statusLabel)
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(economics.verdict.tint)
                Text(economics.verdict.statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text(economics.offer.platform.displayName)
                    .font(.subheadline.weight(.semibold))
                if let product = economics.offer.productName {
                    Text(product)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var rates: some View {
        HStack(spacing: 0) {
            // Captions say what the number MEANS, not what it is called.
            // "net per km" assumes the driver already thinks in the app's
            // vocabulary; "you keep, per km" tells someone on their first shift
            // exactly what they are looking at.
            metric(
                value: NumberParsing.formatRate(economics.netPerKm),
                unit: "\(currency)/km",
                caption: "you keep, per km"
            )
            Divider().frame(height: 34)
            metric(
                value: economics.netPerHour.map { NumberParsing.formatRate($0, decimals: 0) } ?? "—",
                unit: "\(currency)/h",
                caption: "you keep, per hour"
            )
            Divider().frame(height: 34)
            metric(
                value: economics.deadheadRatio.map { NumberParsing.formatRate($0) } ?? "—",
                unit: "×",
                caption: "empty km vs paid km"
            )
        }
    }

    private func metric(value: String, unit: String, caption: String) -> some View {
        VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var breakdown: some View {
        VStack(spacing: 5) {
            row("Fare on the card", NumberParsing.formatMoney(economics.offer.fare, currency: currency))
            if economics.commission > 0.005 {
                row(
                    economics.offer.fareIsNet ? "Gross (reconstructed)" : "Gross",
                    NumberParsing.formatMoney(economics.gross, currency: currency)
                )
                row("Platform commission", "−" + NumberParsing.formatMoney(economics.commission, currency: currency))
            }
            // The number the driver compares between offers, spelled out
            // against the FULL distance rather than the paid leg the platform
            // priced. Sitting directly above the fuel line, it shows exactly
            // what the road takes back.
            row(
                "Per km driven, before fuel",
                "\(NumberParsing.formatRate(economics.earningsPerKm)) \(currency)/km"
            )
            // Distance is spelled out because it is the crux: the platform
            // priced the paid leg, we are costing every kilometre the car moves.
            row(
                "Fuel / energy · \(NumberParsing.formatRate(economics.totalKm, decimals: 1)) km",
                "−" + NumberParsing.formatMoney(economics.energyCost, currency: currency)
            )
            row("Net", NumberParsing.formatMoney(economics.net, currency: currency), emphasised: true)
        }
    }

    private func row(_ label: String, _ value: String, emphasised: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(emphasised ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(emphasised ? .primary : .secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(emphasised ? .subheadline.weight(.bold) : .subheadline)
                .monospacedDigit()
        }
    }

    private var lowConfidenceNote: some View {
        Label(
            economics.offer.parseConfidence < 0.55
                ? "Too little of the card was readable to judge this. Check the numbers yourself."
                : "Some of the card was not readable — treat these numbers as approximate.",
            systemImage: "eye.trianglebadge.exclamationmark"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var accessibilitySummary: String {
        var parts = [
            economics.verdict.statusLabel,
            "net \(NumberParsing.formatMoney(economics.net, currency: currency))",
            "\(NumberParsing.formatRate(economics.netPerKm)) \(currency) per kilometre",
        ]
        if let perHour = economics.netPerHour {
            parts.append("\(NumberParsing.formatRate(perHour, decimals: 0)) \(currency) per hour")
        }
        parts.append(contentsOf: economics.reasons)
        return parts.joined(separator: ", ")
    }
}

/// A dot instead of an SF Symbol at symbol size, so a wrapped reason lines up.
private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            configuration.icon
                .font(.system(size: 5))
                .baselineOffset(2)
            configuration.title
        }
    }
}

#Preview {
    // Transcribed from a real Bolt card: "11,62 lei (NET, taxe incluse)",
    // 2.8 km to collect for a 3 km ride.
    let offer = RideOffer(
        platform: .bolt,
        fare: 11.62,
        currency: "lei",
        pickupKm: 2.8,
        pickupMin: 6,
        tripKm: 3.0,
        tripMin: 6,
        fareIsNet: Platform.bolt.fareShownIsNetByDefault
    )
    let economics = ProfitCalculator(
        vehicle: .defaultRO,
        thresholds: DriverThresholds()
    ).evaluate(offer)

    return Group {
        if let economics {
            VerdictCardView(economics: economics).padding()
        }
    }
}

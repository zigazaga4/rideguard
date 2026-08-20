import Foundation

/// Turns a parsed offer into the numbers a driver cannot compute in the
/// twelve seconds he is given.
///
/// The critical modelling decision: **cost is charged on the FULL distance**,
/// deadhead included. The driver burns fuel getting to the passenger just as
/// surely as carrying them, but the platforms only ever show the fare against
/// the paid leg. That gap is where money quietly disappears, and closing it is
/// the entire point of this app.
public struct ProfitCalculator {
    private let vehicle: VehicleProfile
    private let thresholds: DriverThresholds
    /// Per-platform commission override, resolved per offer.
    private let commissionRateFor: (RideOffer) -> Double

    public init(
        vehicle: VehicleProfile,
        thresholds: DriverThresholds,
        commissionRateFor: @escaping (RideOffer) -> Double = { $0.platform.defaultCommissionRate }
    ) {
        self.vehicle = vehicle
        self.thresholds = thresholds
        self.commissionRateFor = commissionRateFor
    }

    public func evaluate(_ offer: RideOffer) -> OfferEconomics? {
        guard offer.isComputable else { return nil }

        guard let totalKm = offer.chargeableKm else { return nil }
        if totalKm <= 0.0 { return nil }
        let totalMin = offer.totalMin

        // --- Revenue ------------------------------------------------------
        let commissionRate = min(max(commissionRateFor(offer), 0.0), 0.95)
        let gross: Double
        let commission: Double
        if offer.fareIsNet {
            // Card already shows the driver's cut; reconstruct gross for display.
            gross = commissionRate < 1.0 ? offer.fare / (1.0 - commissionRate) : offer.fare
            commission = gross - offer.fare
        } else {
            gross = offer.fare
            commission = gross * commissionRate
        }
        let afterCommission = gross - commission

        // --- Cost, charged on every kilometre the car actually moves ------
        let energyCost = totalKm * vehicle.energyCostPerKm

        let net = afterCommission - energyCost

        // --- Rates --------------------------------------------------------
        let hours: Double? = {
            guard let totalMin, totalMin > 0.0 else { return nil }
            return totalMin / 60.0
        }()
        let earningsPerKm = afterCommission / totalKm
        let netPerKm = net / totalKm
        let netPerHour = hours.map { net / $0 }

        let deadheadRatio = computeDeadheadRatio(offer)

        let (verdict, reasons) = judge(
            net: net,
            netPerKm: netPerKm,
            netPerHour: netPerHour,
            deadheadRatio: deadheadRatio,
            parseConfidence: offer.parseConfidence,
            currency: offer.currency
        )

        return OfferEconomics(
            offer: offer,
            totalKm: totalKm,
            totalMin: totalMin,
            gross: gross,
            commission: commission,
            afterCommission: afterCommission,
            energyCost: energyCost,
            net: net,
            earningsPerKm: earningsPerKm,
            netPerKm: netPerKm,
            netPerHour: netPerHour,
            deadheadRatio: deadheadRatio,
            verdict: verdict,
            reasons: reasons,
            currency: offer.currency
        )
    }

    private func computeDeadheadRatio(_ offer: RideOffer) -> Double? {
        guard let pickup = offer.pickupKm, let trip = offer.tripKm else { return nil }
        if trip <= 0.0 { return nil }
        return pickup / trip
    }

    /// Traffic light. Any hard failure makes it BAD outright; otherwise the
    /// count of soft misses decides between GOOD and MARGINAL.
    ///
    /// We refuse to render a confident verdict on a card we barely understood —
    /// an honest UNKNOWN beats a green light built on a guess. On iOS this
    /// matters more, not less: Vision misreads a glare-washed screenshot far
    /// more readily than an accessibility tree misreads a string.
    private func judge(
        net: Double,
        netPerKm: Double,
        netPerHour: Double?,
        deadheadRatio: Double?,
        parseConfidence: Float,
        currency: String
    ) -> (Verdict, [String]) {
        if parseConfidence < 0.55 {
            return (.unknown, ["Could not read the whole offer card"])
        }

        var reasons: [String] = []

        if net < 0.0 {
            reasons.append("Loses \(NumberParsing.formatMoney(-net, currency: currency)) after fuel")
            return (.bad, reasons)
        }
        if net < thresholds.minNetTotal {
            reasons.append("Net below your \(NumberParsing.formatMoney(thresholds.minNetTotal, currency: currency)) floor")
            return (.bad, reasons)
        }

        var misses = 0

        if netPerKm < thresholds.minNetPerKm {
            misses += 1
            reasons.append(
                "\(NumberParsing.formatRate(netPerKm)) \(currency)/km "
                + "is under your \(NumberParsing.formatRate(thresholds.minNetPerKm)) target"
            )
        }
        if let netPerHour, netPerHour < thresholds.minNetPerHour {
            misses += 1
            reasons.append(
                "\(NumberParsing.formatRate(netPerHour, decimals: 0)) \(currency)/h "
                + "is under your \(NumberParsing.formatRate(thresholds.minNetPerHour, decimals: 0)) target"
            )
        }
        if let deadheadRatio, deadheadRatio > thresholds.maxDeadheadRatio {
            misses += 1
            reasons.append("Long pickup: \(NumberParsing.formatRate(deadheadRatio))× the trip distance")
        }

        if misses == 0 { return (.good, ["Clears every target"]) }
        if misses == 1 { return (.marginal, reasons) }
        return (.bad, reasons)
    }
}

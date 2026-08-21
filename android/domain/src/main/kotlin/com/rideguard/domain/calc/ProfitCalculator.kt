package com.rideguard.domain.calc

import com.rideguard.domain.model.DriverThresholds
import com.rideguard.domain.model.OfferEconomics
import com.rideguard.domain.model.RideOffer
import com.rideguard.domain.model.Verdict
import com.rideguard.domain.model.VehicleProfile
import com.rideguard.domain.parse.NumberParsing

/**
 * Turns a parsed offer into the numbers a driver cannot compute in the
 * twelve seconds he is given.
 *
 * The critical modelling decision: **cost is charged on the FULL distance**,
 * deadhead included. The driver burns fuel and wears tyres getting to the
 * passenger just as surely as carrying them, but the platforms only ever
 * show the fare against the paid leg. That gap is where money quietly
 * disappears, and closing it is the entire point of this app.
 */
class ProfitCalculator(
    private val vehicle: VehicleProfile,
    private val thresholds: DriverThresholds,
    /** Per-platform commission override, keyed by platform. */
    private val commissionRateFor: (RideOffer) -> Double = { it.platform.defaultCommissionRate },
) {

    fun evaluate(offer: RideOffer): OfferEconomics? {
        if (!offer.isComputable) return null

        val totalKm = offer.chargeableKm ?: return null
        if (totalKm <= 0.0) return null
        val totalMin = offer.totalMin

        // --- Revenue ------------------------------------------------------
        val commissionRate = commissionRateFor(offer).coerceIn(0.0, 0.95)
        val gross: Double
        val commission: Double
        if (offer.fareIsNet) {
            // Card already shows the driver's cut; reconstruct gross for display.
            gross = if (commissionRate < 1.0) offer.fare / (1.0 - commissionRate) else offer.fare
            commission = gross - offer.fare
        } else {
            gross = offer.fare
            commission = gross * commissionRate
        }
        val afterCommission = gross - commission

        // --- Cost, charged on every kilometre the car actually moves ------
        val energyCost = totalKm * vehicle.energyCostPerKm

        val net = afterCommission - energyCost

        // --- Rates --------------------------------------------------------
        val hours = totalMin?.takeIf { it > 0.0 }?.let { it / 60.0 }
        val earningsPerKm = afterCommission / totalKm
        val netPerKm = net / totalKm
        val netPerHour = hours?.let { net / it }

        val deadheadRatio = computeDeadheadRatio(offer)

        val (verdict, reasons) = judge(
            net = net,
            netPerKm = netPerKm,
            netPerHour = netPerHour,
            deadheadRatio = deadheadRatio,
            parseConfidence = offer.parseConfidence,
            currency = offer.currency,
        )

        return OfferEconomics(
            offer = offer,
            totalKm = totalKm,
            totalMin = totalMin,
            gross = gross,
            commission = commission,
            afterCommission = afterCommission,
            energyCost = energyCost,
            net = net,
            earningsPerKm = earningsPerKm,
            netPerKm = netPerKm,
            netPerHour = netPerHour,
            deadheadRatio = deadheadRatio,
            verdict = verdict,
            reasons = reasons,
            currency = offer.currency,
            // The same comparison `judge` makes, recorded so the HUD can show
            // the warning badge on exactly the offers the verdict marked down
            // for it, whatever the driver has set the target to.
            deadheadIsExcessive = deadheadRatio != null &&
                deadheadRatio > thresholds.maxDeadheadRatio,
        )
    }

    private fun computeDeadheadRatio(offer: RideOffer): Double? {
        val pickup = offer.pickupKm ?: return null
        val trip = offer.tripKm ?: return null
        if (trip <= 0.0) return null
        return pickup / trip
    }

    /**
     * Traffic light. Any hard failure makes it BAD outright; otherwise the
     * count of soft misses decides between GOOD and MARGINAL.
     *
     * We refuse to render a confident verdict on a card we barely understood —
     * an honest UNKNOWN beats a green light built on a guess.
     */
    private fun judge(
        net: Double,
        netPerKm: Double,
        netPerHour: Double?,
        deadheadRatio: Double?,
        parseConfidence: Float,
        currency: String,
    ): Pair<Verdict, List<String>> {
        if (parseConfidence < 0.55f) {
            return Verdict.UNKNOWN to listOf("Could not read the whole offer card")
        }

        val reasons = mutableListOf<String>()

        if (net < 0.0) {
            reasons += "Loses ${NumberParsing.formatMoney(-net, currency)} after fuel"
            return Verdict.BAD to reasons
        }
        if (net < thresholds.minNetTotal) {
            reasons += "Net below your ${NumberParsing.formatMoney(thresholds.minNetTotal, currency)} floor"
            return Verdict.BAD to reasons
        }

        var misses = 0

        if (netPerKm < thresholds.minNetPerKm) {
            misses++
            reasons += "${NumberParsing.formatRate(netPerKm)} $currency/km " +
                "is under your ${NumberParsing.formatRate(thresholds.minNetPerKm)} target"
        }
        if (netPerHour != null && netPerHour < thresholds.minNetPerHour) {
            misses++
            reasons += "${NumberParsing.formatRate(netPerHour, 0)} $currency/h " +
                "is under your ${NumberParsing.formatRate(thresholds.minNetPerHour, 0)} target"
        }
        if (deadheadRatio != null && deadheadRatio > thresholds.maxDeadheadRatio) {
            misses++
            reasons += "Long pickup: ${NumberParsing.formatRate(deadheadRatio)}× the trip distance"
        }

        return when {
            misses == 0 -> Verdict.GOOD to listOf("Clears every target")
            misses == 1 -> Verdict.MARGINAL to reasons
            else -> Verdict.BAD to reasons
        }
    }
}

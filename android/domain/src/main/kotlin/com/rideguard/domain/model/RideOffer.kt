package com.rideguard.domain.model

/**
 * A ride offer as read off the screen. Raw, pre-economics.
 *
 * Every field the parser could not find stays null rather than being guessed.
 * [ProfitCalculator][com.rideguard.domain.calc.ProfitCalculator] decides what
 * is survivable — a missing passenger rating is fine, a missing fare is not.
 */
data class RideOffer(
    val platform: Platform,
    /** Fare exactly as displayed on the card. */
    val fare: Double,
    val currency: String,
    /** Distance from driver to passenger — the "deadhead" leg. */
    val pickupKm: Double?,
    val pickupMin: Double?,
    /** Distance of the paid leg. */
    val tripKm: Double?,
    val tripMin: Double?,
    /**
     * Whether [fare] is already net of platform commission. Comes from
     * settings per-platform, not from the screen.
     */
    val fareIsNet: Boolean,
    val surgeMultiplier: Double? = null,
    val passengerRating: Double? = null,
    val productName: String? = null,
    val pickupAddress: String? = null,
    val destinationAddress: String? = null,
    val capturedAtMs: Long = 0L,
    /**
     * 0..1 — how much of the card we actually understood. Falls when fields
     * are missing or ambiguous. The HUD dims itself below ~0.6 rather than
     * confidently showing a number built on a guess.
     */
    val parseConfidence: Float = 1f,
) {
    /** Total distance the car actually moves: deadhead + paid leg. */
    val totalKm: Double?
        get() {
            val p = pickupKm ?: return null
            val t = tripKm ?: return null
            return p + t
        }

    /** Total time the driver is committed for. */
    val totalMin: Double?
        get() {
            val p = pickupMin ?: return null
            val t = tripMin ?: return null
            return p + t
        }

    /**
     * Distance we can actually charge cost against: both legs when we have
     * them, otherwise the paid leg alone.
     *
     * Falling back to [tripKm] does understate cost, because it silently
     * ignores the deadhead — which is why any offer that lands here takes a
     * heavy [parseConfidence] penalty and surfaces as UNKNOWN rather than as
     * a confident verdict.
     */
    val chargeableKm: Double?
        get() = totalKm ?: tripKm

    /**
     * Enough to do the maths? Distance and fare are mandatory; time is
     * strongly preferred but we can still show per-km without it.
     */
    val isComputable: Boolean
        get() = fare > 0.0 && (chargeableKm ?: 0.0) > 0.0
}

/** Traffic-light call on an offer. */
enum class Verdict {
    /** Clears every threshold. */
    GOOD,

    /** Clears some, misses others. Driver's judgement. */
    MARGINAL,

    /** Misses the bar, or actively loses money. */
    BAD,

    /** Could not read enough of the card to say. Never bluff here. */
    UNKNOWN,
}

/**
 * The output of the whole pipeline, and exactly what the HUD renders.
 *
 * Kept flat and pre-computed on purpose: the overlay recomposes under time
 * pressure while the driver has ~10-15 seconds to decide, so it should read
 * fields, never calculate.
 */
data class OfferEconomics(
    val offer: RideOffer,
    val totalKm: Double,
    val totalMin: Double?,

    /** Fare before platform commission. */
    val gross: Double,
    /** What the platform keeps. */
    val commission: Double,
    /**
     * What actually reaches the driver's hands before running costs —
     * [gross] minus [commission]. This is the headline the HUD divides by
     * distance, because it is the number the driver recognises as "what this
     * ride pays me".
     */
    val afterCommission: Double,
    /** Fuel or electricity for the whole distance, deadhead included. */
    val energyCost: Double,
    /** What actually lands in the driver's pocket. */
    val net: Double,

    /**
     * THE HEADLINE NUMBER. Earnings per kilometre driven, commission already
     * removed but running costs not yet.
     *
     * Charged against the FULL distance — pickup plus trip — because that is
     * how far the car actually moves. This is what the driver compares between
     * offers, and [netPerKm] sitting directly beneath it shows what the road
     * takes back.
     */
    val earningsPerKm: Double,

    val netPerKm: Double,
    val netPerHour: Double?,

    /** pickupKm ÷ tripKm. The pro signal. Null when either leg is unknown. */
    val deadheadRatio: Double?,

    val verdict: Verdict,
    /** Short human reasons the verdict came out this way, for the detail sheet. */
    val reasons: List<String> = emptyList(),
    val currency: String,
) {
    /** True when the ride costs more to serve than it pays. */
    val isLossMaking: Boolean get() = net < 0.0

    /** Total running cost of serving this ride. Fuel, on every kilometre. */
    val totalCost: Double get() = energyCost

    /** What the road takes out of every kilometre. The gap between the two HUD lines. */
    val costPerKm: Double get() = if (totalKm > 0) totalCost / totalKm else 0.0
}

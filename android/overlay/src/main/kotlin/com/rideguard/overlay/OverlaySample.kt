package com.rideguard.overlay

import com.rideguard.domain.model.OfferEconomics
import com.rideguard.domain.model.Platform
import com.rideguard.domain.model.RideOffer
import com.rideguard.domain.model.Verdict

/**
 * A stand-in offer, shown only while the driver is placing and sizing the HUD.
 *
 * Sizing a window against an empty box tells you nothing about whether the
 * numbers will be readable from a windscreen mount, which is the entire point
 * of the exercise. So adjust mode shows a full card with every row populated.
 *
 * The figures are deliberately the *widest* plausible ones rather than pretty
 * round numbers — a two-digit rate, a negative net, a long context line. If the
 * HUD is legible at the size the driver picks for this, it is legible for
 * anything a real offer will produce.
 *
 * Hand-built rather than run through `ProfitCalculator` because it must render
 * identically whatever the driver has configured; a sample that changes shape
 * with the fuel price makes the size they chose a moving target.
 */
internal object OverlaySample {

    val economics: OfferEconomics = OfferEconomics(
        offer = RideOffer(
            platform = Platform.BOLT,
            fare = 42.50,
            currency = "RON",
            pickupKm = 3.2,
            pickupMin = 7.0,
            tripKm = 9.4,
            tripMin = 21.0,
            fareIsNet = true,
        ),
        totalKm = 12.6,
        totalMin = 28.0,
        gross = 42.50,
        commission = 0.0,
        afterCommission = 42.50,
        energyCost = 6.62,
        net = 35.88,
        earningsPerKm = 3.37,
        netPerKm = 2.85,
        netPerHour = 76.9,
        deadheadRatio = 0.34,
        verdict = Verdict.GOOD,
        reasons = listOf("Clears every target"),
        currency = "RON",
        deadheadIsExcessive = false,
    )
}

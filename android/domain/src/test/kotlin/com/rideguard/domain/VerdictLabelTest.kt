package com.rideguard.domain

import com.rideguard.domain.calc.ProfitCalculator
import com.rideguard.domain.model.DriverThresholds
import com.rideguard.domain.model.FuelType
import com.rideguard.domain.model.Platform
import com.rideguard.domain.model.RideOffer
import com.rideguard.domain.model.Verdict
import com.rideguard.domain.model.VehicleProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The verdict in words, and the warning badge that has to agree with it.
 *
 * The HUD used to carry the verdict entirely in colour, and separately
 * hard-coded the deadhead threshold at 0.8 rather than reading the driver's
 * own. Both are fixed; this is what keeps them fixed.
 *
 * The label strings are asserted literally on purpose. They are the same
 * strings iOS's `Verdict.statusLabel` returns, and a driver checking the same
 * offer on both phones must read the same word.
 */
class VerdictLabelTest {

    private val car = VehicleProfile(
        label = "Logan",
        fuelType = FuelType.PETROL,
        consumptionPer100km = 7.0,
        energyPrice = 7.5,
        currency = "RON",
    )

    @Test
    fun `the labels are the ones the driver was promised`() {
        assertEquals("Profitable", Verdict.GOOD.statusLabel)
        assertEquals("Semi-profitable", Verdict.MARGINAL.statusLabel)
        assertEquals("Not profitable", Verdict.BAD.statusLabel)
    }

    /**
     * The important one. UNKNOWN means the card could not be read, which is not
     * a middle verdict — a driver skimming for the word "profitable" must not
     * find it on an offer the app never actually managed to judge.
     */
    @Test
    fun `unknown never claims anything about profit`() {
        assertFalse(Verdict.UNKNOWN.statusLabel.lowercase().contains("profit"))
        assertFalse(Verdict.UNKNOWN.statusDetail.lowercase().contains("profit"))
    }

    @Test
    fun `every verdict has both strings and no two read alike`() {
        val labels = Verdict.values().map { it.statusLabel }
        for (v in Verdict.values()) {
            assertTrue("$v has no label", v.statusLabel.isNotBlank())
            assertTrue("$v has no detail", v.statusDetail.isNotBlank())
        }
        assertTrue(
            "two verdicts reading the same makes them indistinguishable on the HUD",
            labels.size == labels.toSet().size,
        )
    }

    /**
     * The regression that motivated carrying this flag at all: raise the
     * driver's own pickup-ratio target above the offer's ratio and the badge
     * must go quiet, because the verdict no longer counts it as a miss.
     */
    @Test
    fun `the deadhead badge follows the driver's target, not a hard-coded 0 point 8`() {
        // 5 km pickup against a 5 km trip: a ratio of exactly 1.0.
        val offer = RideOffer(
            platform = Platform.BOLT,
            fare = 40.0,
            currency = "RON",
            pickupKm = 5.0,
            pickupMin = 8.0,
            tripKm = 5.0,
            tripMin = 12.0,
            fareIsNet = false,
            parseConfidence = 1.0f,
        )

        val strict = ProfitCalculator(
            car,
            DriverThresholds(minNetPerHour = 40.0, minNetPerKm = 1.5, maxDeadheadRatio = 0.8),
        ).evaluate(offer)
        assertNotNull(strict)
        assertEquals(1.0, strict!!.deadheadRatio!!, 1e-9)
        assertTrue("1.0 is over a 0.8 target, so the badge must show", strict.deadheadIsExcessive)

        val tolerant = ProfitCalculator(
            car,
            DriverThresholds(minNetPerHour = 40.0, minNetPerKm = 1.5, maxDeadheadRatio = 1.5),
        ).evaluate(offer)
        assertNotNull(tolerant)
        assertFalse(
            "1.0 is inside a 1.5 target, so the badge must not contradict the verdict",
            tolerant!!.deadheadIsExcessive,
        )
    }
}

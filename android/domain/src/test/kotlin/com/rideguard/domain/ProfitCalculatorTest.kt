package com.rideguard.domain

import com.rideguard.domain.calc.ProfitCalculator
import com.rideguard.domain.model.DriverThresholds
import com.rideguard.domain.model.FuelType
import com.rideguard.domain.model.Platform
import com.rideguard.domain.model.RideOffer
import com.rideguard.domain.model.Verdict
import com.rideguard.domain.model.VehicleProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfitCalculatorTest {

    /** 7 L/100km at 7.5 RON/L = 0.525 RON/km. Fuel is the whole cost model. */
    private val car = VehicleProfile(
        label = "Logan",
        fuelType = FuelType.PETROL,
        consumptionPer100km = 7.0,
        energyPrice = 7.5,
        currency = "RON",
    )

    private val thresholds = DriverThresholds(
        minNetPerHour = 40.0,
        minNetPerKm = 1.5,
        maxDeadheadRatio = 0.8,
    )

    private fun calc(commission: Double = 0.0) =
        ProfitCalculator(car, thresholds, commissionRateFor = { commission })

    private fun offer(
        fare: Double,
        pickupKm: Double?,
        pickupMin: Double?,
        tripKm: Double?,
        tripMin: Double?,
        net: Boolean = true,
        confidence: Float = 1f,
    ) = RideOffer(
        platform = Platform.BOLT,
        fare = fare,
        currency = "RON",
        pickupKm = pickupKm,
        pickupMin = pickupMin,
        tripKm = tripKm,
        tripMin = tripMin,
        fareIsNet = net,
        parseConfidence = confidence,
    )

    @Test
    fun `cost is charged on pickup plus trip, not just the paid leg`() {
        // 2 km pickup + 8 km trip = 10 km of real driving.
        val e = calc().evaluate(offer(40.0, 2.0, 5.0, 8.0, 15.0))!!

        assertEquals(10.0, e.totalKm, 1e-9)
        assertEquals(10.0 * 0.525, e.energyCost, 1e-9)   // 5.25
        assertEquals(40.0 - 5.25, e.net, 1e-9)           // 34.75
    }

    @Test
    fun `a good offer clears everything`() {
        // 34.75 net over 10 km and 20 min -> 3.475 RON/km, 104.25 RON/h.
        val e = calc().evaluate(offer(40.0, 2.0, 5.0, 8.0, 15.0))!!

        assertEquals(3.475, e.netPerKm, 1e-6)
        assertEquals(104.25, e.netPerHour!!, 1e-6)
        assertEquals(0.25, e.deadheadRatio!!, 1e-9)
        assertEquals(Verdict.GOOD, e.verdict)
    }

    @Test
    fun `the classic trap - long pickup for a short cheap ride is rejected`() {
        // The offer that LOOKS survivable: 6 lei, 5 km to collect, 2 km paid.
        //
        // On fuel alone this clears zero — 6 lei in, 3.68 of diesel out. That
        // is precisely why "am I losing money" is the wrong question and the
        // thresholds are the right one: 18 minutes of the driver's life for
        // 2.32 lei is 7.75 lei/hour, and no amount of technically-positive
        // arithmetic makes that worth taking.
        val e = calc().evaluate(offer(6.0, 5.0, 12.0, 2.0, 6.0))!!

        assertEquals(7.0, e.totalKm, 1e-9)
        assertEquals(2.5, e.deadheadRatio!!, 1e-9)
        assertEquals(Verdict.BAD, e.verdict)
        assertTrue("misses per-km", e.netPerKm < thresholds.minNetPerKm)
        assertTrue("misses per-hour", e.netPerHour!! < thresholds.minNetPerHour)
    }

    @Test
    fun `deadhead ratio alone can sink an otherwise okay-looking offer`() {
        // Decent per-km and per-hour, but you drive further to collect than
        // you are paid to carry.
        val e = calc().evaluate(offer(30.0, 9.0, 18.0, 6.0, 12.0))!!

        assertTrue(e.deadheadRatio!! > thresholds.maxDeadheadRatio)
        assertTrue(e.reasons.any { it.contains("Long pickup") })
        assertTrue(e.verdict == Verdict.MARGINAL || e.verdict == Verdict.BAD)
    }

    @Test
    fun `gross fare has commission removed before costs`() {
        // Bolt-style: card shows 50 gross, platform takes 20%.
        val e = ProfitCalculator(car, thresholds, commissionRateFor = { 0.20 })
            .evaluate(offer(50.0, 2.0, 5.0, 8.0, 15.0, net = false))!!

        assertEquals(50.0, e.gross, 1e-9)
        assertEquals(10.0, e.commission, 1e-9)
        assertEquals(40.0 - 5.25, e.net, 1e-9)
    }

    @Test
    fun `net fare reconstructs the gross for display`() {
        // Uber-style: card shows 40 already net, platform took 20%.
        val e = ProfitCalculator(car, thresholds, commissionRateFor = { 0.20 })
            .evaluate(offer(40.0, 2.0, 5.0, 8.0, 15.0, net = true))!!

        assertEquals(50.0, e.gross, 1e-6)
        assertEquals(10.0, e.commission, 1e-6)
        assertEquals(40.0 - 5.25, e.net, 1e-9)
    }

    @Test
    fun `a barely-read card returns UNKNOWN rather than bluffing a green light`() {
        val e = calc().evaluate(offer(40.0, 2.0, 5.0, 8.0, 15.0, confidence = 0.4f))!!
        assertEquals(Verdict.UNKNOWN, e.verdict)
    }

    @Test
    fun `missing time still yields per-km numbers`() {
        val e = calc().evaluate(offer(40.0, 2.0, null, 8.0, null))
        assertNotNull(e)
        assertEquals(3.475, e!!.netPerKm, 1e-6)
        assertEquals(null, e.netPerHour)
    }

    @Test
    fun `electric car costs are computed off kWh`() {
        val ev = VehicleProfile(
            fuelType = FuelType.ELECTRIC,
            consumptionPer100km = 18.0,   // kWh/100km
            energyPrice = 1.2,            // RON/kWh
        )
        val e = ProfitCalculator(ev, thresholds, commissionRateFor = { 0.0 })
            .evaluate(offer(40.0, 2.0, 5.0, 8.0, 15.0))!!

        assertEquals(10.0 * 0.216, e.energyCost, 1e-9)
        assertTrue(e.net > 35.0)
    }

    // ---------------------------------------------------------------------
    // Regression guards for what the real driver apps actually print.
    //
    // Both of these are transcribed from screenshots of live offers in
    // Romania. They exist because the app previously assumed Bolt showed a
    // GROSS fare and skimmed 20% off it, which made every Bolt offer read 20%
    // worse than reality. Nothing crashed, no test failed — the numbers were
    // simply, quietly wrong. If someone "restores" a commission default, these
    // two break loudly.
    // ---------------------------------------------------------------------

    @Test
    fun `Bolt card says NET taxe incluse so nothing is skimmed off it`() {
        // Screenshot: "11,62 lei (NET, taxe incluse)", 6 min / 2.8 km pickup,
        // 6 min / 3 km trip.
        val bolt = RideOffer(
            platform = Platform.BOLT,
            fare = 11.62,
            currency = "lei",
            pickupKm = 2.8, pickupMin = 6.0,
            tripKm = 3.0, tripMin = 6.0,
            fareIsNet = Platform.BOLT.fareShownIsNetByDefault,
        )
        val e = ProfitCalculator(
            car,
            thresholds,
            commissionRateFor = { it.platform.defaultCommissionRate },
        ).evaluate(bolt)!!

        // The driver is promised 11.62 and the app must agree, to the cent.
        assertEquals(11.62, e.afterCommission, 1e-9)
        assertEquals(0.0, e.commission, 1e-9)
        assertEquals(5.8, e.totalKm, 1e-9)
        assertEquals(11.62 - 5.8 * 0.525, e.net, 1e-9)   // 8.575
    }

    @Test
    fun `Uber card says castig net fara comisionul Uber so nothing is skimmed off it`() {
        // Screenshot: "78,16 RON", "Câștig net (fără comisionul Uber)",
        // 12 min / 5.4 km pickup, 57 min / 29.0 km trip.
        val uber = RideOffer(
            platform = Platform.UBER,
            fare = 78.16,
            currency = "RON",
            pickupKm = 5.4, pickupMin = 12.0,
            tripKm = 29.0, tripMin = 57.0,
            fareIsNet = Platform.UBER.fareShownIsNetByDefault,
        )
        val e = ProfitCalculator(
            car,
            thresholds,
            commissionRateFor = { it.platform.defaultCommissionRate },
        ).evaluate(uber)!!

        assertEquals(78.16, e.afterCommission, 1e-9)
        assertEquals(34.4, e.totalKm, 1e-9)
        // A genuinely good long run: 1.75 RON/km and 52 RON/h after fuel.
        assertEquals(Verdict.GOOD, e.verdict)
        assertTrue(e.netPerKm > thresholds.minNetPerKm)
        assertTrue(e.netPerHour!! > thresholds.minNetPerHour)
    }
}

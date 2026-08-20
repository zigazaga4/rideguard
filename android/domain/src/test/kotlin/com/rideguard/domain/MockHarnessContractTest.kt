package com.rideguard.domain

import com.rideguard.domain.calc.ProfitCalculator
import com.rideguard.domain.model.Bounds
import com.rideguard.domain.model.DriverThresholds
import com.rideguard.domain.model.Platform
import com.rideguard.domain.model.ScreenSnapshot
import com.rideguard.domain.model.TextBlock
import com.rideguard.domain.model.Verdict
import com.rideguard.domain.model.VehicleProfile
import com.rideguard.domain.parse.OfferParserRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The contract between the Expo mock harness and this parser.
 *
 * Every string below was produced by running `previewLines()` in
 * `mock/src/offerText.ts` — they are byte-for-byte what the mock renders on
 * screen, not a hand-written approximation. That is the entire value of this
 * file: if someone "tidies up" the wording or the number formatting on the
 * React Native side, these tests fail on the JVM in seconds instead of the
 * HUD silently going blank on a real phone mid-shift.
 *
 * To regenerate after changing the mock:
 *
 *   cd mock
 *   npx tsc --ignoreConfig src/offer.ts src/format.ts src/offerText.ts \
 *       --outDir /tmp/mockjs --module commonjs --target es2022 --skipLibCheck
 *   node -e "const{PRESETS,draftToOffer,PLATFORMS}=require('/tmp/mockjs/offer.js');
 *            const{previewLines}=require('/tmp/mockjs/offerText.js');
 *            for(const p of PLATFORMS) for(const s of PRESETS)
 *              console.log(p, s.id, JSON.stringify(previewLines(p,draftToOffer(s.draft,p))))"
 */
class MockHarnessContractTest {

    private val registry = OfferParserRegistry()

    /** Romanian default: 7 L/100km at 7.5 RON/L, plus 0.35/km wear. */
    private val car = VehicleProfile.DEFAULT_RO
    private val thresholds = DriverThresholds()

    /**
     * Builds the snapshot the accessibility service would produce from the
     * mock: one block per rendered `<Text>`, stacked in render order.
     */
    private fun mockScreen(vararg lines: String): ScreenSnapshot {
        var y = 120
        val blocks = lines.map { text ->
            // The marker is rendered at fontSize 1; everything else is normal
            // type. Height feeds the "fare is the largest text" heuristic.
            val h = if (text.startsWith("__rg_platform")) 2 else 36
            TextBlock(text = text, bounds = Bounds(40, y, 660, y + h)).also { y += h + 10 }
        }
        return ScreenSnapshot(
            packageName = OfferParserRegistry.MOCK_PACKAGE,
            blocks = blocks,
            capturedAtMs = 1_700_000_000_000,
        )
    }

    private fun evaluate(snapshot: ScreenSnapshot, commission: Double) =
        registry.parse(snapshot) { it.fareShownIsNetByDefault }?.let { offer ->
            ProfitCalculator(car, thresholds, commissionRateFor = { commission }).evaluate(offer)
        }

    // ------------------------------------------------------------------ Bolt

    private fun boltGood() = mockScreen(
        "__rg_platform=bolt", "Comandă nouă", "Comfort", "40,00 lei", "Preț estimat",
        "4,85 ★", "Preluare", "2,0 km · 5 min", "Strada Victoriei 12",
        "Destinație", "8,0 km · 15 min", "Bulevardul Unirii 45", "Refuză", "Acceptă",
    )

    @Test
    fun `mock routes to the bolt parser via the platform marker`() {
        val offer = registry.parse(boltGood()) { false }
        assertNotNull("marker routing failed — check __rg_platform in offerText.ts", offer)
        assertEquals(Platform.BOLT, offer!!.platform)
    }

    @Test
    fun `bolt good preset parses every field`() {
        val offer = registry.parse(boltGood()) { false }!!

        assertEquals(40.00, offer.fare, 1e-9)
        assertEquals("RON", offer.currency)
        assertEquals(2.0, offer.pickupKm!!, 1e-9)
        assertEquals(5.0, offer.pickupMin!!, 1e-9)
        assertEquals(8.0, offer.tripKm!!, 1e-9)
        assertEquals(15.0, offer.tripMin!!, 1e-9)
        assertEquals(4.85, offer.passengerRating!!, 1e-9)
        assertEquals("Comfort", offer.productName)
        assertEquals(1f, offer.parseConfidence)
    }

    @Test
    fun `bolt good preset is a keeper`() {
        // 40 gross, 20% commission -> 32. 10 km at 0.875/km -> 8.75. Net 23.25.
        val e = evaluate(boltGood(), commission = 0.20)!!
        assertEquals(23.25, e.net, 1e-6)
        assertEquals(2.325, e.netPerKm, 1e-6)
        assertEquals(69.75, e.netPerHour!!, 1e-6)
        assertEquals(0.25, e.deadheadRatio!!, 1e-9)
        assertEquals(Verdict.GOOD, e.verdict)
    }

    @Test
    fun `bolt classic trap loses money`() {
        val e = evaluate(
            mockScreen(
                "__rg_platform=bolt", "Comandă nouă", "Comfort", "6,00 lei", "Preț estimat",
                "4,85 ★", "Preluare", "5,0 km · 12 min", "Strada Victoriei 12",
                "Destinație", "2,0 km · 6 min", "Bulevardul Unirii 45", "Refuză", "Acceptă",
            ),
            commission = 0.20,
        )!!

        assertEquals(7.0, e.totalKm, 1e-9)
        assertTrue("6 lei for 7 km of driving must be loss-making", e.isLossMaking)
        assertEquals(Verdict.BAD, e.verdict)
        assertEquals(2.5, e.deadheadRatio!!, 1e-9)
    }

    @Test
    fun `bolt long deadhead is rejected`() {
        val e = evaluate(
            mockScreen(
                "__rg_platform=bolt", "Comandă nouă", "Comfort", "30,00 lei", "Preț estimat",
                "4,85 ★", "Preluare", "9,0 km · 18 min", "Strada Victoriei 12",
                "Destinație", "6,0 km · 12 min", "Bulevardul Unirii 45", "Refuză", "Acceptă",
            ),
            commission = 0.20,
        )!!

        assertEquals(1.5, e.deadheadRatio!!, 1e-9)
        assertEquals(Verdict.BAD, e.verdict)
        assertTrue(e.reasons.any { it.contains("Long pickup") })
    }

    @Test
    fun `bolt surge chip is read as a multiplier and does not confuse the fare`() {
        val snapshot = mockScreen(
            "__rg_platform=bolt", "Comandă nouă", "Comfort", "1,8×", "Tarif dinamic",
            "85,00 lei", "Preț estimat", "4,85 ★", "Preluare", "3,0 km · 7 min",
            "Strada Victoriei 12", "Destinație", "14,0 km · 26 min",
            "Bulevardul Unirii 45", "Refuză", "Acceptă",
        )
        val offer = registry.parse(snapshot) { false }!!

        assertEquals(85.00, offer.fare, 1e-9)
        assertEquals(1.8, offer.surgeMultiplier!!, 1e-9)
        assertEquals(3.0, offer.pickupKm!!, 1e-9)
        assertEquals(14.0, offer.tripKm!!, 1e-9)
    }

    @Test
    fun `a big fare on a long trip is not automatically a good ride`() {
        // This is the counter-intuitive one, and it is exactly the judgement
        // a driver cannot make in twelve seconds: 120 lei FEELS like a great
        // offer. But 49 km of driving eats 42.87 in fuel and wear, and the
        // platform takes 24 off the top, so it nets 1.08/km — below target.
        // The per-hour figure is fine, which is why it lands on MARGINAL and
        // not BAD. The driver gets to make the call with real numbers.
        val e = evaluate(
            mockScreen(
                "__rg_platform=bolt", "Comandă nouă", "Comfort", "120,00 lei", "Preț estimat",
                "4,85 ★", "Preluare", "4,0 km · 9 min", "Strada Victoriei 12",
                "Destinație", "45,0 km · 55 min", "Bulevardul Unirii 45", "Refuză", "Acceptă",
            ),
            commission = 0.20,
        )!!

        assertEquals(49.0, e.totalKm, 1e-9)
        assertEquals(42.875, e.totalCost, 1e-6)
        assertEquals(53.125, e.net, 1e-6)
        assertEquals(1.084, e.netPerKm, 1e-3)
        assertTrue("per-hour still clears the bar", e.netPerHour!! > thresholds.minNetPerHour)
        assertEquals(Verdict.MARGINAL, e.verdict)
    }

    @Test
    fun `bolt single-distance preset refuses to bluff a verdict`() {
        // No pickup leg on the card. Charging cost against the paid leg alone
        // would flatter the offer, so this must surface as UNKNOWN.
        val snapshot = mockScreen(
            "__rg_platform=bolt", "Comandă nouă", "Comfort", "20,00 lei", "Preț estimat",
            "4,85 ★", "Destinație", "6,0 km · 14 min", "Bulevardul Unirii 45",
            "Refuză", "Acceptă",
        )
        val offer = registry.parse(snapshot) { false }!!
        assertNull(offer.pickupKm)
        assertEquals(6.0, offer.tripKm!!, 1e-9)
        assertTrue("confidence must fall below the UNKNOWN threshold", offer.parseConfidence < 0.55f)

        val e = evaluate(snapshot, commission = 0.20)!!
        assertEquals(Verdict.UNKNOWN, e.verdict)
        assertEquals(6.0, e.totalKm, 1e-9)
    }

    // ------------------------------------------------------------------ Uber

    private fun uberGood() = mockScreen(
        "__rg_platform=uber", "Trip request", "UberX", "€40.00", "Your earnings",
        "★", "4.85", "Pickup", "5 min (2.0 km) away", "Bulevardul Magheru 8",
        "Dropoff", "15 min (8.0 km) trip", "Strada Lipscani 22", "Decline", "Accept",
    )

    @Test
    fun `uber parenthesised legs parse in the right order`() {
        val offer = registry.parse(uberGood()) { true }!!

        assertEquals(Platform.UBER, offer.platform)
        assertEquals(40.00, offer.fare, 1e-9)
        assertEquals("EUR", offer.currency)
        assertEquals(2.0, offer.pickupKm!!, 1e-9)
        assertEquals(5.0, offer.pickupMin!!, 1e-9)
        assertEquals(8.0, offer.tripKm!!, 1e-9)
        assertEquals(15.0, offer.tripMin!!, 1e-9)
        assertEquals("UberX", offer.productName)
    }

    @Test
    fun `uber rating survives being split across two text nodes`() {
        // The mock renders the star glyph and the number as separate <Text>
        // nodes, which is what Uber itself does. The starless-rating fallback
        // is what catches it.
        val offer = registry.parse(uberGood()) { true }!!
        assertEquals(4.85, offer.passengerRating!!, 1e-9)
    }

    @Test
    fun `uber fare shown net is not double-charged commission`() {
        // 40 is already the driver's cut. 10 km at 0.875 -> 8.75. Net 31.25.
        val e = evaluate(uberGood(), commission = 0.25)!!

        assertEquals(53.333333, e.gross, 1e-5)
        assertEquals(13.333333, e.commission, 1e-5)
        assertEquals(31.25, e.net, 1e-6)
        assertEquals(93.75, e.netPerHour!!, 1e-6)
        assertEquals(Verdict.GOOD, e.verdict)
    }

    @Test
    fun `uber classic trap loses money too`() {
        val e = evaluate(
            mockScreen(
                "__rg_platform=uber", "Trip request", "UberX", "€6.00", "Your earnings",
                "★", "4.85", "Pickup", "12 min (5.0 km) away", "Bulevardul Magheru 8",
                "Dropoff", "6 min (2.0 km) trip", "Strada Lipscani 22", "Decline", "Accept",
            ),
            commission = 0.25,
        )!!

        assertTrue(e.isLossMaking)
        assertEquals(Verdict.BAD, e.verdict)
    }

    @Test
    fun `uber surge chip does not steal the fare`() {
        val offer = registry.parse(
            mockScreen(
                "__rg_platform=uber", "Trip request", "UberX", "1.8×", "Surge",
                "€85.00", "Your earnings", "★", "4.85", "Pickup", "7 min (3.0 km) away",
                "Bulevardul Magheru 8", "Dropoff", "26 min (14.0 km) trip",
                "Strada Lipscani 22", "Decline", "Accept",
            ),
        ) { true }!!

        assertEquals(85.00, offer.fare, 1e-9)
        assertEquals(1.8, offer.surgeMultiplier!!, 1e-9)
    }

    // ------------------------------------------------------------- guardrails

    @Test
    fun `street numbers in addresses are never mistaken for offer data`() {
        val offer = registry.parse(boltGood()) { false }!!
        // "Strada Victoriei 12" and "Bulevardul Unirii 45" must contribute
        // nothing — if they leaked in, the legs below would be wrong.
        assertEquals(2.0, offer.pickupKm!!, 1e-9)
        assertEquals(8.0, offer.tripKm!!, 1e-9)
        assertEquals(4.85, offer.passengerRating!!, 1e-9)
    }

    @Test
    fun `the marker alone is not enough - a non-offer screen is still rejected`() {
        val home = mockScreen("__rg_platform=bolt", "Online", "Câștiguri astăzi", "245,00 lei")
        assertNull(registry.parse(home) { false })
    }

    @Test
    fun `an unmarked mock screen routes nowhere`() {
        val unmarked = mockScreen(
            "Comandă nouă", "Comfort", "40,00 lei", "Preluare", "2,0 km · 5 min",
            "Destinație", "8,0 km · 15 min", "Acceptă",
        )
        assertNull(registry.parse(unmarked) { false })
    }
}

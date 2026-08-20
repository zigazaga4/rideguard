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
import com.rideguard.domain.parse.TokenScanner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
 * The mock in turn is a transcription of screenshots of the live Romanian
 * Bolt and Uber driver apps, so these strings are as close to ground truth as
 * anything short of a recorded fixture. Both cards are Romanian, both accept
 * buttons say "Potrivire", both fares are net, and both currencies are RON.
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

    /** Romanian default: 7 L/100km at 7.5 RON/L, so 0.525 RON/km. Fuel only. */
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

    /**
     * Commission defaults to the platform's own rate, which is now 0 on both:
     * the Romanian cards print the driver's net take. Pass [commission] only to
     * model a driver who overrode it in settings.
     */
    private fun evaluate(snapshot: ScreenSnapshot, commission: Double? = null) =
        registry.parse(snapshot) { it.fareShownIsNetByDefault }?.let { offer ->
            val calculator =
                if (commission == null) ProfitCalculator(car, thresholds)
                else ProfitCalculator(car, thresholds, commissionRateFor = { commission })
            calculator.evaluate(offer)
        }

    // ------------------------------------------------ the real screenshots

    /** The `real-bolt` preset: an actual offer, transcribed chip for chip. */
    private fun realBolt() = mockScreen(
        "✕  Refuză",
        "__rg_platform=bolt",
        "🚗 Bolt",
        "💲 Numerar",
        "Cerere mare 1.1x",
        "În afara razei",
        "📍 Locație",
        "⏱ Oră",
        "11,62 lei (NET, taxe incluse)",
        "Respingerea cursei nu va afecta rata de acceptare",
        "Lichi • 5.0 ★",
        "6 min • 2.8 km",
        "Bulevardul Mamaia Nord 2, Năvodari 905750",
        "6 min • 3 km",
        "Azimuth Beach & Lounge, Strada Promenada, Mamaia-Sat 905700",
        "Potrivire",
    )

    /** The `real-uber` preset. Note the long-trip chip and its stray "45 min.". */
    private fun realUber() = mockScreen(
        "__rg_platform=uber",
        "👤 UberX",
        "✕",
        "78,16 RON",
        "Plata în numerar",
        "★ 5,00",
        "Câștig net (fără comisionul Uber)",
        "La 12 min. (5.4 km) distanță",
        "Str. Lirei 35, Constanța",
        "Cursă: 57 min. (29.0 km)",
        "Strada Emil Costinescu 1, Costinești",
        "🔀 Cursă lungă (peste 45 min.)",
        "Potrivire",
    )

    @Test
    fun `mock routes to the bolt parser via the platform marker`() {
        val offer = registry.parse(realBolt()) { false }
        assertNotNull("marker routing failed — check __rg_platform in offerText.ts", offer)
        assertEquals(Platform.BOLT, offer!!.platform)
    }

    @Test
    fun `real bolt card parses every field`() {
        val offer = registry.parse(realBolt()) { true }!!

        // 11.62 has to come out of "11,62 lei (NET, taxe incluse)" — one text
        // node, comma decimal, and a parenthetical the extractor must ignore.
        assertEquals(11.62, offer.fare, 1e-9)
        assertEquals("RON", offer.currency)
        // Minutes come BEFORE kilometres on the real card: "6 min • 2.8 km".
        assertEquals(2.8, offer.pickupKm!!, 1e-9)
        assertEquals(6.0, offer.pickupMin!!, 1e-9)
        assertEquals(3.0, offer.tripKm!!, 1e-9)
        assertEquals(6.0, offer.tripMin!!, 1e-9)
        assertEquals(5.0, offer.passengerRating!!, 1e-9)
        // "Cerere mare 1.1x" — ASCII x, and it must not become the fare.
        assertEquals(1.1, offer.surgeMultiplier!!, 1e-9)
        assertEquals("Bolt", offer.productName)
        assertEquals(1f, offer.parseConfidence)
    }

    @Test
    fun `real bolt offer is BAD once the deadhead is priced`() {
        // 11.62 is already net (the card says "NET, taxe incluse"), so nothing
        // comes off the top. 5.8 km at 0.525 -> 3.045 fuel. Net 8.575, which is
        // 1.48/km — under the 1.50 target — and the driver would cover 2.8 km
        // to earn on 3.0, a 0.93 deadhead ratio against a 0.80 ceiling. Two
        // misses is BAD. This is the offer the driver had ~12 seconds to judge.
        val e = evaluate(realBolt())!!

        assertEquals(5.8, e.totalKm, 1e-9)
        assertEquals(11.62, e.gross, 1e-9)
        assertEquals(0.0, e.commission, 1e-9)
        assertEquals(3.045, e.energyCost, 1e-9)
        assertEquals(3.045, e.totalCost, 1e-9)
        assertEquals(8.575, e.net, 1e-9)
        assertEquals(1.4784482, e.netPerKm, 1e-6)
        assertEquals(42.875, e.netPerHour!!, 1e-6)
        assertEquals(0.9333333, e.deadheadRatio!!, 1e-6)
        assertFalse("it still turns a profit — it just misses the bar", e.isLossMaking)
        assertEquals(Verdict.BAD, e.verdict)
    }

    @Test
    fun `real uber card parses every field`() {
        val offer = registry.parse(realUber()) { true }!!

        assertEquals(Platform.UBER, offer.platform)
        // RON, not euro. The card reads "78,16 RON" with a comma decimal.
        assertEquals(78.16, offer.fare, 1e-9)
        assertEquals("RON", offer.currency)
        // "La 12 min. (5.4 km) distanță" / "Cursă: 57 min. (29.0 km)" —
        // a trailing full stop on the unit, and a label with a colon in front.
        assertEquals(5.4, offer.pickupKm!!, 1e-9)
        assertEquals(12.0, offer.pickupMin!!, 1e-9)
        assertEquals(29.0, offer.tripKm!!, 1e-9)
        assertEquals(57.0, offer.tripMin!!, 1e-9)
        assertEquals(5.0, offer.passengerRating!!, 1e-9)
        assertNull(offer.surgeMultiplier)
        assertEquals("UberX", offer.productName)
        assertEquals(1f, offer.parseConfidence)
    }

    @Test
    fun `real uber offer clears every target`() {
        // 78.16 net, 34.4 km at 0.525 -> 18.06 fuel, 60.10 left. 1.75/km over
        // 69 minutes is 52.26/h, and a 5.4 km pickup for a 29 km ride barely
        // registers as deadhead. Nothing to argue with.
        val e = evaluate(realUber())!!

        assertEquals(34.4, e.totalKm, 1e-9)
        assertEquals(18.06, e.energyCost, 1e-9)
        assertEquals(60.10, e.net, 1e-9)
        assertEquals(1.7470930, e.netPerKm, 1e-6)
        assertEquals(52.2608695, e.netPerHour!!, 1e-6)
        assertEquals(0.1862068, e.deadheadRatio!!, 1e-6)
        assertEquals(Verdict.GOOD, e.verdict)
    }

    @Test
    fun `uber long-trip chip does not steal a leg`() {
        // "🔀 Cursă lungă (peste 45 min.)" is a third duration on the card and
        // there is no way to tell it from a leg by shape alone. It survives
        // only because it renders BELOW both legs and assignment is by reading
        // order — which is exactly why that ordering rule is not negotiable.
        val offer = registry.parse(realUber()) { true }!!
        assertEquals(12.0, offer.pickupMin!!, 1e-9)
        assertEquals(57.0, offer.tripMin!!, 1e-9)
    }

    // ------------------------------------------------------------------ Bolt

    private fun boltGood() = mockScreen(
        "✕  Refuză",
        "__rg_platform=bolt",
        "🚗 Bolt",
        "💲 Numerar",
        "În afara razei",
        "📍 Locație",
        "⏱ Oră",
        "40,00 lei (NET, taxe incluse)",
        "Respingerea cursei nu va afecta rata de acceptare",
        "Lichi • 4.9 ★",
        "5 min • 2 km",
        "Bulevardul Mamaia Nord 2, Năvodari 905750",
        "15 min • 8 km",
        "Azimuth Beach & Lounge, Strada Promenada, Mamaia-Sat 905700",
        "Potrivire",
    )

    @Test
    fun `bolt good preset parses every field`() {
        val offer = registry.parse(boltGood()) { true }!!

        assertEquals(40.00, offer.fare, 1e-9)
        assertEquals("RON", offer.currency)
        assertEquals(2.0, offer.pickupKm!!, 1e-9)
        assertEquals(5.0, offer.pickupMin!!, 1e-9)
        assertEquals(8.0, offer.tripKm!!, 1e-9)
        assertEquals(15.0, offer.tripMin!!, 1e-9)
        assertEquals(4.9, offer.passengerRating!!, 1e-9)
        assertNull(offer.surgeMultiplier)
        assertEquals(1f, offer.parseConfidence)
    }

    @Test
    fun `bolt good preset is a keeper`() {
        // 40 net, 10 km at 0.525 -> 5.25 fuel. Net 34.75 = 3.48/km, 104/h.
        val e = evaluate(boltGood())!!
        assertEquals(34.75, e.net, 1e-9)
        assertEquals(3.475, e.netPerKm, 1e-9)
        assertEquals(104.25, e.netPerHour!!, 1e-6)
        assertEquals(0.25, e.deadheadRatio!!, 1e-9)
        assertEquals(Verdict.GOOD, e.verdict)
    }

    @Test
    fun `bolt classic trap misses every target without losing money`() {
        // CHANGED, honestly: this used to assert isLossMaking. It no longer is.
        // Dropping the invented 0.35/km wear charge and the phantom 20%
        // commission leaves 6 lei against 3.675 of fuel — 2.33 in the driver's
        // pocket for 18 minutes' work. The old assertion was only ever true
        // because of a number nobody could source. It is still an obvious BAD:
        // 0.33/km, 7.75/h and a 2.5 deadhead ratio miss all three targets.
        val e = evaluate(
            mockScreen(
                "✕  Refuză",
                "__rg_platform=bolt",
                "🚗 Bolt",
                "💲 Numerar",
                "În afara razei",
                "📍 Locație",
                "⏱ Oră",
                "6,00 lei (NET, taxe incluse)",
                "Respingerea cursei nu va afecta rata de acceptare",
                "Lichi • 4.9 ★",
                "12 min • 5 km",
                "Bulevardul Mamaia Nord 2, Năvodari 905750",
                "6 min • 2 km",
                "Azimuth Beach & Lounge, Strada Promenada, Mamaia-Sat 905700",
                "Potrivire",
            ),
        )!!

        assertEquals(7.0, e.totalKm, 1e-9)
        assertEquals(3.675, e.totalCost, 1e-9)
        assertEquals(2.325, e.net, 1e-9)
        assertFalse(e.isLossMaking)
        assertEquals(7.75, e.netPerHour!!, 1e-6)
        assertEquals(2.5, e.deadheadRatio!!, 1e-9)
        assertEquals(Verdict.BAD, e.verdict)
    }

    @Test
    fun `bolt long deadhead is rejected`() {
        val e = evaluate(
            mockScreen(
                "✕  Refuză",
                "__rg_platform=bolt",
                "🚗 Bolt",
                "💲 Numerar",
                "În afara razei",
                "📍 Locație",
                "⏱ Oră",
                "30,00 lei (NET, taxe incluse)",
                "Respingerea cursei nu va afecta rata de acceptare",
                "Lichi • 4.9 ★",
                "18 min • 9 km",
                "Bulevardul Mamaia Nord 2, Năvodari 905750",
                "12 min • 6 km",
                "Azimuth Beach & Lounge, Strada Promenada, Mamaia-Sat 905700",
                "Potrivire",
            ),
        )!!

        // 22.125 net over 15 km is 1.475/km — three quarters of a bănuț under
        // target — and the driver covers 9 km to earn on 6. Two misses, BAD.
        assertEquals(1.475, e.netPerKm, 1e-9)
        assertEquals(1.5, e.deadheadRatio!!, 1e-9)
        assertEquals(Verdict.BAD, e.verdict)
        assertTrue(e.reasons.any { it.contains("Long pickup") })
    }

    @Test
    fun `bolt surge chip is read as a multiplier and does not confuse the fare`() {
        val offer = registry.parse(
            mockScreen(
                "✕  Refuză",
                "__rg_platform=bolt",
                "🚗 Bolt",
                "💲 Numerar",
                "Cerere mare 1.8x",
                "În afara razei",
                "📍 Locație",
                "⏱ Oră",
                "85,00 lei (NET, taxe incluse)",
                "Respingerea cursei nu va afecta rata de acceptare",
                "Lichi • 4.9 ★",
                "7 min • 3 km",
                "Bulevardul Mamaia Nord 2, Năvodari 905750",
                "26 min • 14 km",
                "Azimuth Beach & Lounge, Strada Promenada, Mamaia-Sat 905700",
                "Potrivire",
            ),
        ) { true }!!

        assertEquals(85.00, offer.fare, 1e-9)
        assertEquals(1.8, offer.surgeMultiplier!!, 1e-9)
        assertEquals(3.0, offer.pickupKm!!, 1e-9)
        assertEquals(14.0, offer.tripKm!!, 1e-9)
    }

    @Test
    fun `a big fare on a long trip clears the bar once invented costs are gone`() {
        // CHANGED, honestly: this used to land on MARGINAL, and the comment
        // above it explained at length why 120 lei "feels" better than it is.
        // That reasoning depended on a 20% commission Bolt does not take on a
        // net-quoted fare and on 0.35/km of wear nobody could put a number to.
        // With fuel alone, 49 km costs 25.73 and the ride nets 1.92/km at
        // 88/h. Manufacturing pessimism is as wrong as manufacturing optimism.
        val e = evaluate(
            mockScreen(
                "✕  Refuză",
                "__rg_platform=bolt",
                "🚗 Bolt",
                "💲 Numerar",
                "În afara razei",
                "📍 Locație",
                "⏱ Oră",
                "120,00 lei (NET, taxe incluse)",
                "Respingerea cursei nu va afecta rata de acceptare",
                "Lichi • 4.9 ★",
                "9 min • 4 km",
                "Bulevardul Mamaia Nord 2, Năvodari 905750",
                "55 min • 45 km",
                "Azimuth Beach & Lounge, Strada Promenada, Mamaia-Sat 905700",
                "Potrivire",
            ),
        )!!

        assertEquals(49.0, e.totalKm, 1e-9)
        assertEquals(25.725, e.totalCost, 1e-9)
        assertEquals(94.275, e.net, 1e-9)
        assertEquals(1.9239795, e.netPerKm, 1e-6)
        assertEquals(88.3828125, e.netPerHour!!, 1e-6)
        assertEquals(Verdict.GOOD, e.verdict)
    }

    @Test
    fun `bolt single-distance preset refuses to bluff a verdict`() {
        // No pickup leg on the card. Charging cost against the paid leg alone
        // would flatter the offer, so this must surface as UNKNOWN.
        val snapshot = mockScreen(
            "✕  Refuză",
            "__rg_platform=bolt",
            "🚗 Bolt",
            "💲 Numerar",
            "În afara razei",
            "📍 Locație",
            "⏱ Oră",
            "20,00 lei (NET, taxe incluse)",
            "Respingerea cursei nu va afecta rata de acceptare",
            "Lichi • 4.9 ★",
            "14 min • 6 km",
            "Azimuth Beach & Lounge, Strada Promenada, Mamaia-Sat 905700",
            "Potrivire",
        )
        val offer = registry.parse(snapshot) { true }!!
        assertNull(offer.pickupKm)
        assertEquals(6.0, offer.tripKm!!, 1e-9)
        assertTrue("confidence must fall below the UNKNOWN threshold", offer.parseConfidence < 0.55f)

        val e = evaluate(snapshot)!!
        assertEquals(Verdict.UNKNOWN, e.verdict)
        assertEquals(6.0, e.totalKm, 1e-9)
    }

    // ------------------------------------------------------------------ Uber

    private fun uberGood() = mockScreen(
        "__rg_platform=uber",
        "👤 UberX",
        "✕",
        "40,00 RON",
        "Plata în numerar",
        "★ 4,90",
        "Câștig net (fără comisionul Uber)",
        "La 5 min. (2.0 km) distanță",
        "Str. Lirei 35, Constanța",
        "Cursă: 15 min. (8.0 km)",
        "Strada Emil Costinescu 1, Costinești",
        "Potrivire",
    )

    @Test
    fun `uber parenthesised legs parse in the right order`() {
        val offer = registry.parse(uberGood()) { true }!!

        assertEquals(Platform.UBER, offer.platform)
        assertEquals(40.00, offer.fare, 1e-9)
        assertEquals("RON", offer.currency)
        assertEquals(2.0, offer.pickupKm!!, 1e-9)
        assertEquals(5.0, offer.pickupMin!!, 1e-9)
        assertEquals(8.0, offer.tripKm!!, 1e-9)
        assertEquals(15.0, offer.tripMin!!, 1e-9)
        assertEquals(4.9, offer.passengerRating!!, 1e-9)
        assertEquals("UberX", offer.productName)
    }

    @Test
    fun `uber fare shown net is not double-charged a driver-set commission`() {
        // The platform default is 0 now, but a driver who has checked a payout
        // statement can still set one. 40 is his cut either way; the 25% is
        // reconstructed upwards for display and must never be taken off again.
        val e = evaluate(uberGood(), commission = 0.25)!!

        assertEquals(53.333333, e.gross, 1e-5)
        assertEquals(13.333333, e.commission, 1e-5)
        assertEquals(40.0, e.afterCommission, 1e-9)
        assertEquals(34.75, e.net, 1e-9)
        assertEquals(104.25, e.netPerHour!!, 1e-6)
        assertEquals(Verdict.GOOD, e.verdict)
    }

    @Test
    fun `uber classic trap misses every target`() {
        val e = evaluate(
            mockScreen(
                "__rg_platform=uber",
                "👤 UberX",
                "✕",
                "6,00 RON",
                "Plata în numerar",
                "★ 4,90",
                "Câștig net (fără comisionul Uber)",
                "La 12 min. (5.0 km) distanță",
                "Str. Lirei 35, Constanța",
                "Cursă: 6 min. (2.0 km)",
                "Strada Emil Costinescu 1, Costinești",
                "Potrivire",
            ),
        )!!

        assertEquals(2.325, e.net, 1e-9)
        assertEquals(2.5, e.deadheadRatio!!, 1e-9)
        assertEquals(Verdict.BAD, e.verdict)
    }

    @Test
    fun `uber surge chip does not steal the fare`() {
        val offer = registry.parse(
            mockScreen(
                "__rg_platform=uber",
                "👤 UberX",
                "✕",
                "85,00 RON",
                "Plata în numerar",
                "★ 4,90",
                "Cerere mare 1.8x",
                "Câștig net (fără comisionul Uber)",
                "La 7 min. (3.0 km) distanță",
                "Str. Lirei 35, Constanța",
                "Cursă: 26 min. (14.0 km)",
                "Strada Emil Costinescu 1, Costinești",
                "Potrivire",
            ),
        ) { true }!!

        assertEquals(85.00, offer.fare, 1e-9)
        assertEquals(1.8, offer.surgeMultiplier!!, 1e-9)
        assertEquals(3.0, offer.pickupKm!!, 1e-9)
        assertEquals(14.0, offer.tripKm!!, 1e-9)
    }

    @Test
    fun `uber long trip preset shows the chip and still reads both legs`() {
        val offer = registry.parse(
            mockScreen(
                "__rg_platform=uber",
                "👤 UberX",
                "✕",
                "120,00 RON",
                "Plata în numerar",
                "★ 4,90",
                "Câștig net (fără comisionul Uber)",
                "La 9 min. (4.0 km) distanță",
                "Str. Lirei 35, Constanța",
                "Cursă: 55 min. (45.0 km)",
                "Strada Emil Costinescu 1, Costinești",
                "🔀 Cursă lungă (peste 45 min.)",
                "Potrivire",
            ),
        ) { true }!!

        assertEquals(4.0, offer.pickupKm!!, 1e-9)
        assertEquals(9.0, offer.pickupMin!!, 1e-9)
        assertEquals(45.0, offer.tripKm!!, 1e-9)
        assertEquals(55.0, offer.tripMin!!, 1e-9)
        assertEquals(1f, offer.parseConfidence)
    }

    // ------------------------------------------------------------- guardrails

    /**
     * THE guardrail. Every address the mock renders, scanned on its own.
     *
     * These blocks sit directly under the leg they belong to, so anything they
     * leak lands in the middle of the leg list and comes out looking like real
     * data. `905750` is a postcode, `2` and `35` and `1` are street numbers,
     * and "Lirei" contains what a careless currency regex reads as "lei".
     */
    @Test
    fun `addresses contribute no tokens at all`() {
        val addresses = listOf(
            "Bulevardul Mamaia Nord 2, Năvodari 905750",
            "Azimuth Beach & Lounge, Strada Promenada, Mamaia-Sat 905700",
            "Str. Lirei 35, Constanța",
            "Strada Emil Costinescu 1, Costinești",
        )
        for (address in addresses) {
            val tokens = TokenScanner.scanBlock(TextBlock(address))
            assertEquals("«$address» leaked $tokens", emptyList<Any>(), tokens)
        }
    }

    @Test
    fun `no chip or caption on either card leaks a number`() {
        // Everything on the cards that is NOT a fare, a leg or a rating. A
        // stray Money token here would be picked up by the fare heuristic on
        // a tie; a stray Distance would shift both legs by one.
        val noise = listOf(
            "✕  Refuză", "🚗 Bolt", "💲 Numerar", "În afara razei", "📍 Locație", "⏱ Oră",
            "Respingerea cursei nu va afecta rata de acceptare",
            "👤 UberX", "✕", "Plata în numerar", "Câștig net (fără comisionul Uber)",
            "Potrivire", "__rg_platform=bolt", "__rg_platform=uber",
        )
        for (text in noise) {
            val tokens = TokenScanner.scanBlock(TextBlock(text))
            assertEquals("«$text» leaked $tokens", emptyList<Any>(), tokens)
        }
    }

    @Test
    fun `street numbers and postcodes are never mistaken for offer data`() {
        val offer = registry.parse(realBolt()) { true }!!
        // If "…Nord 2, Năvodari 905750" had contributed anything, the legs
        // below would be wrong and the fare might not be 11.62 at all.
        assertEquals(11.62, offer.fare, 1e-9)
        assertEquals(2.8, offer.pickupKm!!, 1e-9)
        assertEquals(3.0, offer.tripKm!!, 1e-9)
        assertEquals(5.0, offer.passengerRating!!, 1e-9)
    }

    @Test
    fun `the marker alone is not enough - a non-offer screen is still rejected`() {
        val home = mockScreen("__rg_platform=bolt", "Online", "Câștiguri astăzi", "245,00 lei")
        assertNull(registry.parse(home) { false })
    }

    @Test
    fun `an unmarked mock screen routes nowhere`() {
        val unmarked = mockScreen(
            "🚗 Bolt", "11,62 lei (NET, taxe incluse)", "6 min • 2.8 km",
            "6 min • 3 km", "Potrivire",
        )
        assertNull(registry.parse(unmarked) { false })
    }
}

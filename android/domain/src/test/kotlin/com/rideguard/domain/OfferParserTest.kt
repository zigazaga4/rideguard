package com.rideguard.domain

import com.rideguard.domain.model.Bounds
import com.rideguard.domain.model.Platform
import com.rideguard.domain.model.ScreenSnapshot
import com.rideguard.domain.model.TextBlock
import com.rideguard.domain.parse.BoltOfferParser
import com.rideguard.domain.parse.OfferParserRegistry
import com.rideguard.domain.parse.Token
import com.rideguard.domain.parse.TokenScanner
import com.rideguard.domain.parse.UberOfferParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Fixtures shaped like the real Romanian cards, under the real package names.
 *
 * `MockHarnessContractTest` pins the exact strings the Expo harness renders;
 * this file is where the awkward variants live — the older `2,4 km · 5 min`
 * ordering, sub-kilometre legs, a card with two money values on it, and the
 * near-misses that a careless regex would swallow.
 *
 * Replace these with genuine captures the moment record mode has run for a
 * shift — `ReplaySource` reads the same JSON these mimic, so real fixtures
 * drop straight in and these tests become the regression suite.
 */
class OfferParserTest {

    /** Builds a block stack laid out top-to-bottom, like a real offer card. */
    private fun card(pkg: String, vararg rows: Pair<String, Int>): ScreenSnapshot {
        var y = 100
        val blocks = rows.map { (text, height) ->
            val b = TextBlock(text = text, bounds = Bounds(40, y, 640, y + height))
            y += height + 12
            b
        }
        return ScreenSnapshot(packageName = pkg, blocks = blocks, capturedAtMs = 1_700_000_000_000)
    }

    private fun boltCard() = card(
        Platform.BOLT.packageName,
        "✕  Refuză" to 34,
        "🚗 Comfort" to 34,
        "32,50 lei (NET, taxe incluse)" to 96,   // headline fare, biggest type
        "Lichi • 4.9 ★" to 30,
        "5 min • 2.4 km" to 36,                  // pickup leg, minutes first
        "Bulevardul Mamaia Nord 2, Năvodari 905750" to 32,
        "18 min • 8.1 km" to 36,                 // paid leg
        "Potrivire" to 56,
    )

    private fun uberCard() = card(
        Platform.UBER.packageName,
        "👤 UberX" to 34,
        "14,20 RON" to 96,
        "★ 4,85" to 30,
        "La 5 min. (2.4 km) distanță" to 36,
        "Str. Lirei 35, Constanța" to 32,
        "Cursă: 18 min. (8.1 km)" to 36,
        "Potrivire" to 56,
    )

    @Test
    fun `bolt card parses with romanian comma decimals`() {
        val offer = BoltOfferParser().parse(boltCard(), fareIsNet = true)
        assertNotNull(offer)
        offer!!

        assertEquals(Platform.BOLT, offer.platform)
        assertEquals(32.50, offer.fare, 1e-9)
        assertEquals("RON", offer.currency)
        assertEquals(2.4, offer.pickupKm!!, 1e-9)
        assertEquals(5.0, offer.pickupMin!!, 1e-9)
        assertEquals(8.1, offer.tripKm!!, 1e-9)
        assertEquals(18.0, offer.tripMin!!, 1e-9)
        assertEquals(10.5, offer.totalKm!!, 1e-9)
        assertEquals("Comfort", offer.productName)
        assertEquals(4.9, offer.passengerRating!!, 1e-9)
        assertTrue(offer.parseConfidence > 0.9f)
    }

    @Test
    fun `bolt legs parse whichever way round the app writes them`() {
        // The Romanian card writes `6 min • 2.8 km`; older builds and other
        // markets write `2,4 km · 5 min`. Distances and durations are assigned
        // independently precisely so neither ordering needs its own parser.
        val legacy = card(
            Platform.BOLT.packageName,
            "Comandă nouă" to 40,
            "32,50 lei" to 96,
            "2,4 km · 5 min" to 36,
            "8,1 km · 18 min" to 36,
            "Acceptă" to 56,
        )
        val offer = BoltOfferParser().parse(legacy, fareIsNet = false)!!
        assertEquals(2.4, offer.pickupKm!!, 1e-9)
        assertEquals(5.0, offer.pickupMin!!, 1e-9)
        assertEquals(8.1, offer.tripKm!!, 1e-9)
        assertEquals(18.0, offer.tripMin!!, 1e-9)
    }

    @Test
    fun `uber card parses romanian legs with a trailing full stop on the unit`() {
        val offer = UberOfferParser().parse(uberCard(), fareIsNet = true)
        assertNotNull(offer)
        offer!!

        assertEquals(14.20, offer.fare, 1e-9)
        assertEquals("RON", offer.currency)
        assertEquals(2.4, offer.pickupKm!!, 1e-9)
        assertEquals(8.1, offer.tripKm!!, 1e-9)
        assertEquals(5.0, offer.pickupMin!!, 1e-9)
        assertEquals(18.0, offer.tripMin!!, 1e-9)
        assertEquals(4.85, offer.passengerRating!!, 1e-9)
        assertEquals("UberX", offer.productName)
    }

    @Test
    fun `the headline fare wins over smaller money on the card`() {
        val snap = card(
            Platform.BOLT.packageName,
            "Cursă nouă" to 40,
            "45,00 lei" to 96,       // the fare
            "bonus 5,00 lei" to 28,  // small print
            "4 min • 2,0 km" to 36,
            "20 min • 9,0 km" to 36,
            "Potrivire" to 56,
        )
        val offer = BoltOfferParser().parse(snap, fareIsNet = true)!!
        assertEquals(45.00, offer.fare, 1e-9)
    }

    @Test
    fun `a single distance leaves pickup unknown instead of assuming zero`() {
        // Assuming a zero-km pickup would flatter the offer exactly when the
        // driver most needs the truth. We drop confidence instead.
        val snap = card(
            Platform.BOLT.packageName,
            "✕  Refuză" to 34,
            "20,00 lei (NET, taxe incluse)" to 96,
            "14 min • 6 km" to 36,
            "Potrivire" to 56,
        )
        val offer = BoltOfferParser().parse(snap, fareIsNet = true)!!
        assertNull(offer.pickupKm)
        assertEquals(6.0, offer.tripKm!!, 1e-9)
        assertTrue(offer.parseConfidence < 0.75f)
    }

    @Test
    fun `non-offer screens are rejected by the gate`() {
        val home = card(
            Platform.BOLT.packageName,
            "Online" to 40,
            "Câștiguri astăzi" to 34,
            "245,00 lei" to 60,
        )
        assertFalse(BoltOfferParser().canParse(home))
    }

    @Test
    fun `registry routes by package name`() {
        val registry = OfferParserRegistry()

        val bolt = registry.parse(boltCard()) { true }
        assertEquals(Platform.BOLT, bolt!!.platform)

        val uber = registry.parse(uberCard()) { true }
        assertEquals(Platform.UBER, uber!!.platform)

        val stranger = card("com.example.other", "10,00 lei" to 60, "5,0 km" to 30, "accept" to 40)
        assertNull(registry.parse(stranger) { false })
    }

    @Test
    fun `metres do not get mistaken for minutes`() {
        val snap = card(
            Platform.BOLT.packageName,
            "✕  Refuză" to 34,
            "12,00 lei (NET, taxe incluse)" to 96,
            "3 min • 800 m" to 36,
            "9 min • 4 km" to 36,
            "Potrivire" to 56,
        )
        val offer = BoltOfferParser().parse(snap, fareIsNet = true)!!
        assertEquals(0.8, offer.pickupKm!!, 1e-9)
        assertEquals(3.0, offer.pickupMin!!, 1e-9)
        assertEquals(4.0, offer.tripKm!!, 1e-9)
        assertEquals(9.0, offer.tripMin!!, 1e-9)
    }

    // -------------------------------------------------- scanner near-misses

    private fun tokensOf(text: String) = TokenScanner.scanBlock(TextBlock(text))

    @Test
    fun `a full stop after min is part of the unit, not a sentence`() {
        assertEquals(
            listOf(12.0, 57.0),
            listOf("La 12 min. (5.4 km) distanță", "Cursă: 57 min. (29.0 km)")
                .flatMap { tokensOf(it).filterIsInstance<Token.Duration>() }
                .map { it.minutes },
        )
        // …and the metres rule must not claim the `m` of `min.` as a unit.
        assertEquals(
            listOf(5.4),
            tokensOf("La 12 min. (5.4 km) distanță").filterIsInstance<Token.Distance>().map { it.km },
        )
    }

    @Test
    fun `an ascii x surge chip reads as a multiplier and not as money`() {
        val tokens = tokensOf("Cerere mare 1.1x")
        assertEquals(listOf(1.1), tokens.filterIsInstance<Token.Multiplier>().map { it.factor })
        assertTrue("a surge chip is not a fare", tokens.none { it is Token.Money })
    }

    @Test
    fun `the x in a romanian word is not a multiplier`() {
        // "11,62 lei (NET, taxe incluse)" is one text node on the real card,
        // and `taxe` sits a space away from the amount.
        val tokens = tokensOf("11,62 lei (NET, taxe incluse)")
        assertEquals(listOf(11.62), tokens.filterIsInstance<Token.Money>().map { it.value })
        assertTrue(tokens.none { it is Token.Multiplier })
    }

    @Test
    fun `a currency code inside a word is not money`() {
        // "Lirei" ends in what an unbounded alternation reads as "lei", and
        // the street number sits right next to it.
        assertTrue(tokensOf("Str. Lirei 35, Constanța").none { it is Token.Money })
        // "din" is Romanian for "from" long before it is a Serbian dinar.
        assertTrue(tokensOf("2 curse din 5 acceptate").none { it is Token.Money })
    }

    @Test
    fun `a short distance is not read as a passenger rating`() {
        // "5,0 km" is six characters with a perfectly plausible 5.0 in it. The
        // starless-rating fallback only fires on a block that yielded nothing.
        val tokens = tokensOf("5,0 km")
        assertEquals(listOf(5.0), tokens.filterIsInstance<Token.Distance>().map { it.km })
        assertTrue(tokens.none { it is Token.Rating })
    }

    @Test
    fun `a rating is read whichever side of the number the star sits`() {
        assertEquals(
            listOf(5.0, 5.0),
            listOf("Lichi • 5.0 ★", "★ 5,00")
                .flatMap { tokensOf(it).filterIsInstance<Token.Rating>() }
                .map { it.stars },
        )
    }

    @Test
    fun `thousands grouped with a non-breaking space still parse as money`() {
        // Both apps group with U+00A0 once a fare reaches four figures, and
        // Kotlin's `\s` does not match it.
        assertEquals(
            listOf(1234.50),
            tokensOf("1 234,50 lei").filterIsInstance<Token.Money>().map { it.value },
        )
    }
}

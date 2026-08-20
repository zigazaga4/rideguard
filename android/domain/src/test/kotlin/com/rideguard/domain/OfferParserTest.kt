package com.rideguard.domain

import com.rideguard.domain.model.Bounds
import com.rideguard.domain.model.Platform
import com.rideguard.domain.model.ScreenSnapshot
import com.rideguard.domain.model.TextBlock
import com.rideguard.domain.parse.BoltOfferParser
import com.rideguard.domain.parse.OfferParserRegistry
import com.rideguard.domain.parse.UberOfferParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Synthetic fixtures standing in for real recorded ones.
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
        "Comandă nouă" to 40,
        "Comfort" to 34,
        "32,50 lei" to 96,          // headline fare, biggest type
        "4,85 ★" to 30,
        "2,4 km · 5 min" to 36,     // pickup leg
        "Strada Victoriei 12" to 32,
        "8,1 km · 18 min" to 36,    // paid leg
        "Acceptă" to 56,
    )

    private fun uberCard() = card(
        Platform.UBER.packageName,
        "UberX" to 34,
        "€14.20" to 96,
        "4.85" to 30,
        "5 min (2.4 km) away" to 36,
        "18 min (8.1 km) trip" to 36,
        "Accept" to 56,
    )

    @Test
    fun `bolt card parses with romanian comma decimals`() {
        val offer = BoltOfferParser().parse(boltCard(), fareIsNet = false)
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
        assertEquals(4.85, offer.passengerRating!!, 1e-9)
        assertTrue(offer.parseConfidence > 0.9f)
    }

    @Test
    fun `uber card parses with dot decimals and parenthesised legs`() {
        val offer = UberOfferParser().parse(uberCard(), fareIsNet = true)
        assertNotNull(offer)
        offer!!

        assertEquals(14.20, offer.fare, 1e-9)
        assertEquals("EUR", offer.currency)
        assertEquals(2.4, offer.pickupKm!!, 1e-9)
        assertEquals(8.1, offer.tripKm!!, 1e-9)
        assertEquals(5.0, offer.pickupMin!!, 1e-9)
        assertEquals(18.0, offer.tripMin!!, 1e-9)
        assertEquals("UberX", offer.productName)
    }

    @Test
    fun `the headline fare wins over smaller money on the card`() {
        val snap = card(
            Platform.BOLT.packageName,
            "Cursă nouă" to 40,
            "45,00 lei" to 96,       // the fare
            "bonus 5,00 lei" to 28,  // small print
            "2,0 km · 4 min" to 36,
            "9,0 km · 20 min" to 36,
            "Acceptă" to 56,
        )
        val offer = BoltOfferParser().parse(snap, fareIsNet = false)!!
        assertEquals(45.00, offer.fare, 1e-9)
    }

    @Test
    fun `a single distance leaves pickup unknown instead of assuming zero`() {
        // Assuming a zero-km pickup would flatter the offer exactly when the
        // driver most needs the truth. We drop confidence instead.
        val snap = card(
            Platform.BOLT.packageName,
            "Comandă nouă" to 40,
            "20,00 lei" to 96,
            "6,0 km · 14 min" to 36,
            "Acceptă" to 56,
        )
        val offer = BoltOfferParser().parse(snap, fareIsNet = false)!!
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

        val bolt = registry.parse(boltCard()) { false }
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
            "Comandă nouă" to 40,
            "12,00 lei" to 96,
            "800 m · 3 min" to 36,
            "4,0 km · 9 min" to 36,
            "Acceptă" to 56,
        )
        val offer = BoltOfferParser().parse(snap, fareIsNet = false)!!
        assertEquals(0.8, offer.pickupKm!!, 1e-9)
        assertEquals(3.0, offer.pickupMin!!, 1e-9)
        assertEquals(4.0, offer.tripKm!!, 1e-9)
    }
}

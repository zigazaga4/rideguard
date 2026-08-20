package com.rideguard.domain.parse

import com.rideguard.domain.model.Platform
import com.rideguard.domain.model.ScreenSnapshot

/**
 * Bolt Driver — `ee.mtakso.driver`
 * (Bolt was formerly Taxify, an Estonian company: hence the `ee` / `mtakso`.)
 *
 * The Romanian card carries no "Comandă nouă" header at all — it is a chip
 * row, a fare, two legs and two buttons. What it does show is `🚗 Bolt`,
 * `💲 Numerar`, `Cerere mare 1.1x` and a white `✕ Refuză` pill floating on the
 * map, so those are what the gate leans on.
 */
class BoltOfferParser(
    hints: ParserHints = ParserHints(
        offerKeywords = ParserHints.DEFAULT_OFFER_KEYWORDS + listOf(
            "bolt", "comandă nouă", "cursă nouă", "cerere mare", "new order", "new ride",
        ),
    ),
) : HeuristicOfferParser(Platform.BOLT, hints) {

    /**
     * Order matters. "Bolt" is the base tier and is what the real chip says,
     * but the word also appears in the mock harness's `__rg_platform=bolt`
     * marker and in Bolt's own branding elsewhere on screen — so it goes LAST,
     * where it can only win if no specific tier was found.
     */
    private val products = listOf(
        "Comfort", "XL", "Green", "Pet", "Assist", "Business", "Bolt Plus", "Economy", "Send",
        "Bolt",
    )

    override fun detectProduct(snapshot: ScreenSnapshot): String? {
        val text = snapshot.flatText
        return products.firstOrNull { text.contains(it, ignoreCase = true) }
    }
}

/**
 * Uber Driver — `com.ubercab.driver`
 *
 * The Romanian card reads `La 12 min. (5.4 km) distanță` for the deadhead and
 * `Cursă: 57 min. (29.0 km)` for the paid leg — a label and a colon in front
 * of the numbers on one, a trailing word on the other. Both fall out of the
 * shared reading-order heuristic, since it never tries to pair a distance with
 * the duration next to it.
 *
 * The fare is labelled `Câștig net (fără comisionul Uber)` — net of Uber's cut
 * already, which is why [Platform.fareShownIsNetByDefault] is true.
 */
class UberOfferParser(
    hints: ParserHints = ParserHints(
        offerKeywords = ParserHints.DEFAULT_OFFER_KEYWORDS + listOf(
            "uber", "câștig net", "exclusive", "match", "surge", "promotion", "include",
        ),
    ),
) : HeuristicOfferParser(Platform.UBER, hints) {

    private val products = listOf(
        "UberX", "Comfort", "Green", "Black", "XL", "Pet", "Pool", "Connect", "Share", "Taxi",
    )

    override fun detectProduct(snapshot: ScreenSnapshot): String? {
        val text = snapshot.flatText
        return products.firstOrNull { text.contains(it, ignoreCase = true) }
    }
}

package com.rideguard.domain.parse

import com.rideguard.domain.model.Platform
import com.rideguard.domain.model.ScreenSnapshot

/**
 * Bolt Driver — `ee.mtakso.driver`
 * (Bolt was formerly Taxify, an Estonian company: hence the `ee` / `mtakso`.)
 *
 * TUNING NOTE: the keyword and product lists below are the first thing to
 * adjust once real fixtures land. Capture a shift with record mode on, then
 * tighten these against the actual strings Bolt renders in your market and
 * language.
 */
class BoltOfferParser(
    hints: ParserHints = ParserHints(
        offerKeywords = ParserHints.DEFAULT_OFFER_KEYWORDS + listOf(
            "bolt", "comandă nouă", "cursă nouă", "new order", "new ride",
        ),
    ),
) : HeuristicOfferParser(Platform.BOLT, hints) {

    private val products = listOf(
        "Comfort", "XL", "Green", "Pet", "Assist", "Business", "Bolt Plus", "Economy", "Send",
    )

    override fun detectProduct(snapshot: ScreenSnapshot): String? {
        val text = snapshot.flatText
        return products.firstOrNull { text.contains(it, ignoreCase = true) }
    }
}

/**
 * Uber Driver — `com.ubercab.driver`
 *
 * Uber's card usually reads "N min (X km) away" for the deadhead leg and
 * "M min (Y km) trip" for the paid leg, which the shared reading-order
 * heuristic already handles correctly. Uber also tends to show the fare
 * NET of commission, unlike Bolt — see [Platform.fareShownIsNetByDefault].
 */
class UberOfferParser(
    hints: ParserHints = ParserHints(
        offerKeywords = ParserHints.DEFAULT_OFFER_KEYWORDS + listOf(
            "uber", "exclusive", "match", "surge", "promotion", "include",
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

package com.rideguard.domain.parse

import com.rideguard.domain.model.Platform
import com.rideguard.domain.model.RideOffer
import com.rideguard.domain.model.ScreenSnapshot

/**
 * Tunables for the heuristic assembly step.
 *
 * These are the knobs to turn once we have real recorded fixtures from a
 * shift. Until then the defaults encode how both Bolt and Uber lay out an
 * offer card: headline fare in the largest type, pickup leg above the paid
 * leg, in reading order.
 */
data class ParserHints(
    /** Pickup distance/time appears ABOVE the trip distance/time on the card. */
    val pickupBeforeTrip: Boolean = true,
    /** The fare is the largest text on the card. Nearly always true. */
    val fareIsLargestText: Boolean = true,
    /** Sanity clamps — anything outside these is a misread, not a real offer. */
    val minFare: Double = 0.5,
    val maxFare: Double = 10_000.0,
    val maxLegKm: Double = 500.0,
    val maxLegMinutes: Double = 600.0,
    /** Words that mark this as an offer card rather than any other screen. */
    val offerKeywords: List<String> = DEFAULT_OFFER_KEYWORDS,
) {
    companion object {
        /**
         * Multilingual on purpose — Romanian first, since that is the primary
         * market here, then English. Matching is case-insensitive substring.
         */
        val DEFAULT_OFFER_KEYWORDS = listOf(
            // Romanian. "potrivire" is the accept verb on BOTH real cards —
            // neither Bolt nor Uber says "Acceptă" or "Accept" anywhere in the
            // Romanian build, so without it the gate leans entirely on words
            // that only one of the two happens to show.
            "potrivire", "accept", "acceptă", "refuz", "refuză", "respinge",
            "cursă", "comandă", "preluare", "destinaț", "client", "numerar",
            // English
            "decline", "dismiss", "pickup", "pick up", "dropoff", "drop off",
            "away", "trip", "ride", "fare", "rider", "passenger",
        )
    }
}

/** Turns a screen reading into a structured offer, or null if it is not one. */
interface OfferParser {
    val platform: Platform

    /** Cheap gate — is this even an offer card? Runs before the real work. */
    fun canParse(snapshot: ScreenSnapshot): Boolean

    /** Full parse. Returns null when the card cannot be understood. */
    fun parse(snapshot: ScreenSnapshot, fareIsNet: Boolean): RideOffer?
}

/**
 * Shared assembly logic for every platform.
 *
 * Bolt and Uber differ in wording and styling but not in structure: one
 * headline fare, a deadhead leg, and a paid leg, laid out top to bottom.
 * Subclasses override only what genuinely differs, so adding inDrive or
 * Free Now later is one small class, not a new pipeline.
 */
abstract class HeuristicOfferParser(
    override val platform: Platform,
    protected val hints: ParserHints = ParserHints(),
) : OfferParser {

    override fun canParse(snapshot: ScreenSnapshot): Boolean {
        if (snapshot.isEmpty()) return false
        val tokens = TokenScanner.scan(snapshot)
        val hasMoney = tokens.any { it is Token.Money }
        val hasDistance = tokens.any { it is Token.Distance }
        if (!hasMoney || !hasDistance) return false

        val haystack = snapshot.flatText.lowercase()
        return hints.offerKeywords.any { haystack.contains(it) }
    }

    override fun parse(snapshot: ScreenSnapshot, fareIsNet: Boolean): RideOffer? {
        val tokens = TokenScanner.scan(snapshot)

        val fareToken = pickFare(tokens) ?: return null
        if (fareToken.value < hints.minFare || fareToken.value > hints.maxFare) return null

        val distances = tokens.filterIsInstance<Token.Distance>()
            .filter { it.km > 0.0 && it.km <= hints.maxLegKm }
        val durations = tokens.filterIsInstance<Token.Duration>()
            .filter { it.minutes > 0.0 && it.minutes <= hints.maxLegMinutes }

        val (pickupKm, tripKm) = assignLegs(distances.map { it.km })
        val (pickupMin, tripMin) = assignLegs(durations.map { it.minutes })

        // A missing DISTANCE leg is disqualifying on its own.
        //
        // Without the deadhead we would charge cost against the paid leg only,
        // which systematically flatters the offer — and it flatters it worst
        // on exactly the long-pickup rides this app exists to catch. The 0.50
        // penalty is tuned to drop a single missing leg below the calculator's
        // 0.55 UNKNOWN threshold, so the HUD dims and says so instead of
        // showing a confident green number built on an omission.
        //
        // A missing TIME leg only costs us the per-hour figure, so it is cheap.
        var confidence = 1.0f
        if (pickupKm == null) confidence -= 0.50f
        if (tripKm == null) confidence -= 0.50f
        if (pickupMin == null) confidence -= 0.10f
        if (tripMin == null) confidence -= 0.10f
        if (distances.size > 3 || durations.size > 3) confidence -= 0.10f

        if (tripKm == null && pickupKm == null) return null

        return RideOffer(
            platform = platform,
            fare = fareToken.value,
            currency = fareToken.currency,
            pickupKm = pickupKm,
            pickupMin = pickupMin,
            tripKm = tripKm,
            tripMin = tripMin,
            fareIsNet = fareIsNet,
            surgeMultiplier = tokens.filterIsInstance<Token.Multiplier>()
                .firstOrNull { it.factor > 1.0 }?.factor,
            passengerRating = tokens.filterIsInstance<Token.Rating>().firstOrNull()?.stars,
            productName = detectProduct(snapshot),
            pickupAddress = null,
            destinationAddress = null,
            capturedAtMs = snapshot.capturedAtMs,
            parseConfidence = confidence.coerceIn(0f, 1f),
        )
    }

    /**
     * The fare is the biggest money on the card. We use text height as a
     * proxy for font size; when bounds are unavailable (degenerate tree, or
     * an OCR source without geometry) we fall back to the largest value,
     * which is the right guess when the card also shows a small bonus line.
     */
    protected open fun pickFare(tokens: List<Token>): Token.Money? {
        val money = tokens.filterIsInstance<Token.Money>()
        if (money.isEmpty()) return null
        if (money.size == 1) return money.first()

        if (hints.fareIsLargestText) {
            val tallest = money.maxByOrNull { it.source.glyphHeight }
            if (tallest != null && tallest.source.glyphHeight > 0) {
                val ties = money.filter { it.source.glyphHeight == tallest.source.glyphHeight }
                return ties.maxByOrNull { it.value }
            }
        }
        return money.maxByOrNull { it.value }
    }

    /**
     * Two legs, in reading order: deadhead first, paid leg second.
     *
     * Distances and durations are assigned SEPARATELY, which is what lets the
     * same code read both `6 min • 2.8 km` (Bolt, minutes first) and
     * `La 12 min. (5.4 km) distanță` (Uber, minutes first but parenthesised)
     * and the older `2,4 km · 5 min` orders. Pairing the two inside a block
     * would have to know which app wrote it; only the vertical order matters,
     * and that is the same everywhere.
     *
     * With only one value we cannot know which leg it is, so we assign it to
     * the trip and leave pickup null — the confidence penalty above makes the
     * HUD dim itself rather than quietly assuming a zero-km pickup, which
     * would flatter the offer exactly when the driver needs the truth.
     */
    protected open fun assignLegs(values: List<Double>): Pair<Double?, Double?> = when {
        values.isEmpty() -> null to null
        values.size == 1 -> null to values[0]
        hints.pickupBeforeTrip -> values[0] to values[1]
        else -> values[1] to values[0]
    }

    /** Product/tier name, e.g. "Comfort", "UberX". Overridden per platform. */
    protected open fun detectProduct(snapshot: ScreenSnapshot): String? = null
}

/**
 * Picks the right parser for a snapshot and runs it.
 *
 * Adding a platform means adding one entry here — nothing in capture,
 * calculation or the overlay changes.
 */
class OfferParserRegistry(
    private val parsers: List<OfferParser> = listOf(BoltOfferParser(), UberOfferParser()),
    /**
     * Route the mock harness too. The Expo test app cannot claim Bolt's or
     * Uber's package name, so it declares which one it is imitating via an
     * on-screen marker instead. Costs nothing in production — a real driver
     * app never renders this string — and it is what lets the whole pipeline
     * be exercised on demand instead of waiting for a real ride request.
     */
    private val allowMockHarness: Boolean = true,
) {
    fun parserFor(packageName: String): OfferParser? =
        parsers.firstOrNull { it.platform.packageName == packageName }

    fun parse(snapshot: ScreenSnapshot, fareIsNet: (Platform) -> Boolean): RideOffer? {
        val parser = resolveParser(snapshot) ?: return null
        if (!parser.canParse(snapshot)) return null
        return parser.parse(snapshot, fareIsNet(parser.platform))
    }

    private fun resolveParser(snapshot: ScreenSnapshot): OfferParser? {
        parserFor(snapshot.packageName)?.let { return it }
        if (allowMockHarness && snapshot.packageName == MOCK_PACKAGE) {
            return MOCK_MARKER.find(snapshot.flatText)
                ?.groupValues?.get(1)
                ?.lowercase()
                ?.let { name -> parsers.firstOrNull { it.platform.name.equals(name, ignoreCase = true) } }
        }
        return null
    }

    companion object {
        /** The Expo mock driver app. Must match its `android.package`. */
        const val MOCK_PACKAGE = "com.rideguard.mock"

        /** e.g. `__rg_platform=bolt`. Rendered tiny and near-transparent by the mock. */
        private val MOCK_MARKER = Regex("""__rg_platform\s*=\s*(\w+)""", RegexOption.IGNORE_CASE)
    }
}

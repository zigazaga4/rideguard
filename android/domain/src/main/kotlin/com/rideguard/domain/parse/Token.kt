package com.rideguard.domain.parse

import com.rideguard.domain.model.ScreenSnapshot
import com.rideguard.domain.model.TextBlock

/**
 * A meaningful value lifted out of a text block, with the block it came from
 * so we can still reason about WHERE on screen it was.
 */
sealed interface Token {
    val source: TextBlock

    data class Money(val value: Double, val currency: String, override val source: TextBlock) : Token
    data class Distance(val km: Double, override val source: TextBlock) : Token
    data class Duration(val minutes: Double, override val source: TextBlock) : Token
    data class Rating(val stars: Double, override val source: TextBlock) : Token
    data class Multiplier(val factor: Double, override val source: TextBlock) : Token
}

/**
 * Pulls typed tokens out of raw on-screen text.
 *
 * Shared by every platform parser — Bolt and Uber format their cards
 * differently but they both write money as money and kilometres as
 * kilometres, so the scanning is common and only the ASSEMBLY differs.
 *
 * ## The rule that governs every regex here
 *
 * **A number only becomes a token when it is welded to its unit.** Offer cards
 * are full of numbers that mean nothing to us: street numbers, six-digit
 * postcodes, "peste 45 min.", block numbers, apartment numbers. Real captures
 * put them one text node away from the fare:
 *
 *     Bulevardul Mamaia Nord 2, Năvodari 905750
 *     Str. Lirei 35, Constanța
 *
 * If `905750` ever reached the fare, or `2` ever reached a leg, the driver
 * would be shown a confident, plausible, wrong number — which is worse than
 * showing nothing. So each unit sits at most ONE space from its number, and
 * the alphabetic currency codes are word-bounded. Without the boundary `lei`
 * matches inside "Lirei" and a street name becomes a fare.
 */
object TokenScanner {

    /**
     * Space-like characters, written as escapes on purpose.
     *
     * Both apps group thousands with a non-breaking or narrow space and
     * Kotlin's `\s` matches none of them. Spelled literally these are
     * indistinguishable from U+0020 in a diff, and this file had already lost
     * them once to a paste that normalised them — which silently broke
     * `1 234,50 lei`. Raw strings do not process `\u`, so the regex engine
     * gets the escape and reads it itself.
     */
    private const val SPACE_CHARS = """ \t\u00A0\u2007\u2009\u202F"""
    private const val SPACE = """[$SPACE_CHARS]"""

    /**
     * Money only. Fares carry grouping separators (`1 234,50`); distances and
     * durations never do, and letting them would re-open the "2, Năvodari"
     * hole where a comma and a space get swallowed on the way to a unit.
     */
    private const val NUM = """\d[\d.,$SPACE_CHARS]*"""

    /** One plain number. This is all a unit is ever allowed to sit next to. */
    private const val DECIMAL = """\d+(?:[.,]\d+)?"""

    /**
     * Currency markers seen across Bolt/Uber markets, split in two because
     * only the ASCII codes can carry a `\b` — a boundary next to `€` or `лв`
     * would never match, since neither is a word character.
     *
     * `din` (Serbian dinar) is deliberately absent: it is also the commonest
     * preposition in Romanian, and this app's primary market is Romania, so
     * "5 din 10" would have outbid a real 11,62 lei fare in [pickFare]
     * [HeuristicOfferParser.pickFare]. RSD is still readable as `RSD`.
     */
    private const val WORD_CURRENCY =
        """lei|RON|EUR|USD|GBP|PLN|CZK|HUF|UAH|GEL|KZT|BGN|RSD|MDL|TRY|CHF|SEK|NOK|DKK|kr|Ft"""
    private const val SYMBOL_CURRENCY = """zł|Kč|лв|₴|₾|₸|₺|€|\$|£"""
    private const val CURRENCY = """(?:\b(?:$WORD_CURRENCY)\b|$SYMBOL_CURRENCY)"""

    private val CURRENCY_NAMES = mapOf(
        "lei" to "RON", "ron" to "RON",
        "€" to "EUR", "eur" to "EUR",
        "\$" to "USD", "usd" to "USD",
        "£" to "GBP", "gbp" to "GBP",
        "zł" to "PLN", "pln" to "PLN",
        "kč" to "CZK", "czk" to "CZK",
        "ft" to "HUF", "huf" to "HUF",
        "₴" to "UAH", "uah" to "UAH",
        "₾" to "GEL", "gel" to "GEL",
        "₸" to "KZT", "kzt" to "KZT",
        "₺" to "TRY", "try" to "TRY",
        "лв" to "BGN", "bgn" to "BGN",
        "rsd" to "RSD",
        "mdl" to "MDL",
    )

    private val MONEY_SYMBOL_FIRST = Regex("""($CURRENCY)$SPACE*($NUM)""", RegexOption.IGNORE_CASE)
    private val MONEY_SYMBOL_LAST = Regex("""($NUM)$SPACE*($CURRENCY)""", RegexOption.IGNORE_CASE)

    private val KM = Regex("""($DECIMAL)$SPACE?(?:km|КМ)\b""", RegexOption.IGNORE_CASE)

    /**
     * Metres. Four digits at most, at most one space, and `m` must not be the
     * start of a word — that is what keeps "min", "min." and a street number
     * followed by "Mamaia" out of the distance list.
     */
    private val METRES = Regex("""(\d{1,4})$SPACE?m(?![a-zA-Z])""", RegexOption.IGNORE_CASE)
    private val MILES = Regex("""($DECIMAL)$SPACE?(?:mi|miles?)\b""", RegexOption.IGNORE_CASE)

    private val HOURS_AND_MINUTES =
        Regex("""(\d+)$SPACE*(?:h|hr|hrs|hour|hours|ore|oră)$SPACE*(\d+)$SPACE*(?:m|min|mins|minute|minutes)?\b""", RegexOption.IGNORE_CASE)

    /**
     * `\b` after the unit rather than a literal end, so Uber's `12 min.` and
     * Bolt's `6 min` both land — the full stop IS part of what Uber renders.
     */
    private val MINUTES = Regex("""(\d+)$SPACE*(?:min|mins|minut|minute|minutes)\b""", RegexOption.IGNORE_CASE)
    private val HOURS_ONLY = Regex("""(\d+)$SPACE*(?:h|hr|hrs|hour|hours|ore|oră)\b""", RegexOption.IGNORE_CASE)

    private val RATING = Regex("""(?:★|⭐)$SPACE*(\d[.,]\d{1,2})|(\d[.,]\d{1,2})$SPACE*(?:★|⭐)""")
    private val BARE_RATING = Regex("""\b([45][.,]\d{1,2})\b""")

    /**
     * Surge, written `1.1x` on the real Bolt chip (plain ASCII `x`, not `×`).
     *
     * The `x` must not be the first letter of a word, or "taxe incluse" and
     * every Romanian sentence with an `x` in it turns into a multiplier.
     */
    private val MULTIPLIER = Regex(
        """(\d(?:[.,]\d{1,2})?)$SPACE?[x×](?![a-zA-Z0-9])|(?<![a-zA-Z0-9])[x×]$SPACE?(\d(?:[.,]\d{1,2})?)""",
        RegexOption.IGNORE_CASE,
    )

    fun scan(snapshot: ScreenSnapshot): List<Token> =
        snapshot.inReadingOrder.flatMap { scanBlock(it) }

    fun scanBlock(block: TextBlock): List<Token> {
        val text = block.text
        if (text.isBlank()) return emptyList()

        val tokens = mutableListOf<Token>()
        tokens += scanMoney(text, block)
        tokens += scanDistance(text, block)
        tokens += scanDuration(text, block)
        tokens += scanMultiplier(text, block)
        // The starless rating fallback is only safe in a block that yielded
        // nothing else. Otherwise a short leg like "5,0 km" — six characters,
        // and a perfectly good 5.0 in the middle — becomes a phantom passenger
        // rating on a card that never showed one.
        tokens += scanRating(text, block, allowBare = tokens.isEmpty())
        return tokens
    }

    private fun scanMoney(text: String, block: TextBlock): List<Token.Money> {
        val out = mutableListOf<Token.Money>()
        val claimed = mutableSetOf<IntRange>()

        fun consider(range: IntRange, numberPart: String, currencyPart: String) {
            if (claimed.any { it.first <= range.last && range.first <= it.last }) return
            val value = NumberParsing.parseDecimal(numberPart) ?: return
            claimed += range
            out += Token.Money(value, normalizeCurrency(currencyPart), block)
        }

        MONEY_SYMBOL_FIRST.findAll(text).forEach {
            consider(it.range, it.groupValues[2], it.groupValues[1])
        }
        MONEY_SYMBOL_LAST.findAll(text).forEach {
            consider(it.range, it.groupValues[1], it.groupValues[2])
        }
        return out
    }

    private fun scanDistance(text: String, block: TextBlock): List<Token.Distance> {
        val km = KM.findAll(text).mapNotNull { m ->
            NumberParsing.parseDecimal(m.groupValues[1])?.let { Token.Distance(it, block) }
        }.toList()
        if (km.isNotEmpty()) return km

        val miles = MILES.findAll(text).mapNotNull { m ->
            NumberParsing.parseDecimal(m.groupValues[1])?.let { Token.Distance(it * 1.609344, block) }
        }.toList()
        if (miles.isNotEmpty()) return miles

        return METRES.findAll(text).mapNotNull { m ->
            NumberParsing.parseDecimal(m.groupValues[1])?.let { Token.Distance(it / 1000.0, block) }
        }.toList()
    }

    private fun scanDuration(text: String, block: TextBlock): List<Token.Duration> {
        HOURS_AND_MINUTES.find(text)?.let { m ->
            val h = m.groupValues[1].toDoubleOrNull() ?: 0.0
            val mm = m.groupValues[2].toDoubleOrNull() ?: 0.0
            return listOf(Token.Duration(h * 60 + mm, block))
        }
        val mins = MINUTES.findAll(text).mapNotNull { m ->
            m.groupValues[1].toDoubleOrNull()?.let { Token.Duration(it, block) }
        }.toList()
        if (mins.isNotEmpty()) return mins

        return HOURS_ONLY.findAll(text).mapNotNull { m ->
            m.groupValues[1].toDoubleOrNull()?.let { Token.Duration(it * 60, block) }
        }.toList()
    }

    private fun scanRating(text: String, block: TextBlock, allowBare: Boolean): List<Token.Rating> {
        // The star may lead (Uber's `★ 5,00`) or trail (Bolt's `Lichi • 5.0 ★`),
        // and on Bolt it shares the node with the passenger's name.
        RATING.find(text)?.let { m ->
            val raw = m.groupValues[1].ifBlank { m.groupValues[2] }
            NumberParsing.parseDecimal(raw)?.let { return listOf(Token.Rating(it, block)) }
        }
        // No star at all: only trust a bare 4.xx/5.xx in a short, otherwise
        // empty block, which is the shape a rating-only node actually has.
        if (allowBare && text.length <= 6) {
            BARE_RATING.find(text)?.let { m ->
                NumberParsing.parseDecimal(m.groupValues[1])?.let { v ->
                    if (v in 1.0..5.0) return listOf(Token.Rating(v, block))
                }
            }
        }
        return emptyList()
    }

    private fun scanMultiplier(text: String, block: TextBlock): List<Token.Multiplier> =
        MULTIPLIER.findAll(text).mapNotNull { m ->
            val raw = m.groupValues[1].ifBlank { m.groupValues[2] }
            NumberParsing.parseDecimal(raw)?.takeIf { it in 1.0..10.0 }?.let { Token.Multiplier(it, block) }
        }.toList()

    private fun normalizeCurrency(raw: String): String {
        val key = raw.trim().lowercase()
        return CURRENCY_NAMES[key] ?: raw.trim().uppercase()
    }
}

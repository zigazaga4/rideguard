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
 */
object TokenScanner {

    /** Currency markers seen across Bolt/Uber markets. Order matters: longest first. */
    private const val CURRENCY_ALTERNATION =
        """lei|RON|EUR|USD|GBP|PLN|CZK|HUF|UAH|GEL|KZT|BGN|RSD|MDL|TRY|CHF|SEK|NOK|DKK|""" +
            """zł|Kč|Ft|лв|din|₴|₾|₸|₺|€|\$|£|kr"""

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
        "din" to "RSD", "rsd" to "RSD",
        "mdl" to "MDL",
    )

    private const val NUM = """\d[\d.,     ]*"""

    private val MONEY_SYMBOL_FIRST = Regex("""($CURRENCY_ALTERNATION)\s*($NUM)""", RegexOption.IGNORE_CASE)
    private val MONEY_SYMBOL_LAST = Regex("""($NUM)\s*($CURRENCY_ALTERNATION)""", RegexOption.IGNORE_CASE)

    private val KM = Regex("""($NUM)\s*(?:km|КМ)\b""", RegexOption.IGNORE_CASE)

    /** Metres — `m` not followed by `in`/`i`, so we never eat "min" or "mi". */
    private val METRES = Regex("""($NUM)\s*m(?![a-z])""", RegexOption.IGNORE_CASE)
    private val MILES = Regex("""($NUM)\s*(?:mi|miles?)\b""", RegexOption.IGNORE_CASE)

    private val HOURS_AND_MINUTES =
        Regex("""(\d+)\s*(?:h|hr|hrs|hour|hours|ore|oră)\s*(\d+)\s*(?:m|min|mins|minute|minutes)?\b""", RegexOption.IGNORE_CASE)
    private val MINUTES = Regex("""(\d+)\s*(?:min|mins|minute|minutes|minut|minute)\b""", RegexOption.IGNORE_CASE)
    private val HOURS_ONLY = Regex("""(\d+)\s*(?:h|hr|hrs|hour|hours|ore|oră)\b""", RegexOption.IGNORE_CASE)

    private val RATING = Regex("""(?:★|⭐)\s*(\d[.,]\d{1,2})|(\d[.,]\d{1,2})\s*(?:★|⭐)""")
    private val BARE_RATING = Regex("""\b([45][.,]\d{1,2})\b""")
    private val MULTIPLIER = Regex("""(\d(?:[.,]\d{1,2})?)\s*[x×]|[x×]\s*(\d(?:[.,]\d{1,2})?)""", RegexOption.IGNORE_CASE)

    fun scan(snapshot: ScreenSnapshot): List<Token> =
        snapshot.inReadingOrder.flatMap { scanBlock(it) }

    fun scanBlock(block: TextBlock): List<Token> {
        val text = block.text
        if (text.isBlank()) return emptyList()

        val tokens = mutableListOf<Token>()
        tokens += scanMoney(text, block)
        tokens += scanDistance(text, block)
        tokens += scanDuration(text, block)
        tokens += scanRating(text, block)
        tokens += scanMultiplier(text, block)
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

    private fun scanRating(text: String, block: TextBlock): List<Token.Rating> {
        RATING.find(text)?.let { m ->
            val raw = m.groupValues[1].ifBlank { m.groupValues[2] }
            NumberParsing.parseDecimal(raw)?.let { return listOf(Token.Rating(it, block)) }
        }
        // Only accept a bare 4.xx/5.xx as a rating when the block is short —
        // otherwise "4,85 km" style text would masquerade as a star rating.
        if (text.length <= 6) {
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

package com.rideguard.domain.parse

/**
 * Locale-tolerant number parsing.
 *
 * This exists because `"17,50".toDouble()` throws and `"1.234"` silently
 * parses as 1.234 when the driver meant 1234. In Romania — where Bolt is
 * dominant — fares render as `17,50 lei` and distances as `2,4 km`. Get this
 * wrong and every downstream number is quietly, plausibly incorrect, which is
 * far worse than crashing.
 *
 * Rules, applied in order:
 *  1. Strip currency symbols, spaces, and thin/non-breaking spaces.
 *  2. If BOTH `.` and `,` appear, the one that appears LAST is the decimal
 *     separator and the other is grouping. Handles `1.234,56` and `1,234.56`.
 *  3. If only one appears MORE THAN ONCE, it is grouping. `1.234.567`.
 *  4. If only one appears ONCE, look at the digits after it:
 *     exactly 3  -> grouping (`1.234` = 1234, the standard convention)
 *     1 or 2     -> decimal  (`17,50` = 17.5, `2,4` = 2.4)
 *     otherwise  -> decimal
 */
object NumberParsing {

    private val THIN_SPACES = charArrayOf(' ', ' ', ' ', ' ', ' ')

    /** Grabs the first numeric-looking run out of arbitrary text. */
    private val NUMERIC_RUN = Regex("""-?\d[\d.,     ]*\d|-?\d""")

    /**
     * Parse the first number found in [raw], tolerating either decimal
     * convention. Returns null when there is no number at all.
     */
    fun parseDecimal(raw: String?): Double? {
        if (raw.isNullOrBlank()) return null
        val match = NUMERIC_RUN.find(raw) ?: return null

        var s = match.value
        for (c in THIN_SPACES) s = s.replace(c.toString(), "")
        if (s.isEmpty()) return null

        val negative = s.startsWith('-')
        if (negative) s = s.substring(1)

        val lastDot = s.lastIndexOf('.')
        val lastComma = s.lastIndexOf(',')
        val dotCount = s.count { it == '.' }
        val commaCount = s.count { it == ',' }

        val normalized: String = when {
            // Both separators present: the later one is the decimal point.
            lastDot >= 0 && lastComma >= 0 -> {
                if (lastDot > lastComma) {
                    s.replace(",", "")
                } else {
                    s.replace(".", "").replace(',', '.')
                }
            }

            // Only dots.
            lastDot >= 0 -> {
                if (dotCount > 1) s.replace(".", "")
                else if (isGroupingByDigitCount(s, lastDot)) s.replace(".", "")
                else s
            }

            // Only commas.
            lastComma >= 0 -> {
                if (commaCount > 1) s.replace(",", "")
                else if (isGroupingByDigitCount(s, lastComma)) s.replace(",", "")
                else s.replace(',', '.')
            }

            else -> s
        }

        val value = normalized.toDoubleOrNull() ?: return null
        return if (negative) -value else value
    }

    /**
     * A lone separator with exactly three digits after it is a thousands
     * separator by convention (`1.234`). One or two digits means decimals.
     */
    private fun isGroupingByDigitCount(s: String, sepIndex: Int): Boolean {
        val after = s.length - sepIndex - 1
        val before = sepIndex
        return after == 3 && before > 0
    }

    /**
     * Format for the HUD. Deliberately terse — the overlay is small and the
     * driver reads it in about two seconds.
     */
    fun formatMoney(value: Double, currency: String, decimals: Int = 2): String {
        val rounded = roundTo(value, decimals)
        val text = trimTrailingZeros(rounded, decimals)
        return "$text $currency"
    }

    fun formatRate(value: Double, decimals: Int = 2): String =
        trimTrailingZeros(roundTo(value, decimals), decimals)

    /**
     * Fixed decimals, zeros kept.
     *
     * The two per-kilometre lines in the HUD sit directly above one another
     * and are meant to be read as a pair. Trimming turns 4.00 into "4" while
     * 3.13 keeps both places, and the mismatch makes the pair look like two
     * unrelated numbers instead of a before/after. Alignment is the whole
     * point, so these keep their zeros.
     */
    fun formatFixed(value: Double, decimals: Int = 2): String =
        String.format(java.util.Locale.US, "%.${decimals}f", roundTo(value, decimals))

    /**
     * Picks the decimal count from the magnitude.
     *
     * Fixed decimals lie at the extremes: rounding -0.42 to zero places gives
     * "0", which on a loss-making ride reads as "breaks even" when the truth is
     * "you are paying to drive". Small numbers keep their decimals; large ones
     * drop them so the HUD stays narrow.
     */
    fun formatAuto(value: Double): String {
        val magnitude = if (value < 0) -value else value
        val decimals = when {
            magnitude >= 100.0 -> 0
            magnitude >= 10.0 -> 1
            else -> 2
        }
        return formatRate(value, decimals)
    }

    fun roundTo(value: Double, decimals: Int): Double {
        var factor = 1.0
        repeat(decimals) { factor *= 10 }
        return Math.round(value * factor) / factor
    }

    private fun trimTrailingZeros(value: Double, decimals: Int): String {
        val s = String.format(java.util.Locale.US, "%.${decimals}f", value)
        return if (s.contains('.')) s.trimEnd('0').trimEnd('.') else s
    }
}

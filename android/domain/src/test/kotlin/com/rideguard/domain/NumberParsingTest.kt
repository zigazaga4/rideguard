package com.rideguard.domain

import com.rideguard.domain.parse.NumberParsing
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * These are not academic. Romanian Bolt renders `17,50 lei` and `2,4 km`;
 * a naive `toDouble()` throws on the first and a naive comma-strip turns
 * `1.234` into 1.234 when the driver meant 1234. Every one of these cases
 * has a real screen behind it.
 */
class NumberParsingTest {

    private fun p(s: String?) = NumberParsing.parseDecimal(s)

    @Test
    fun `romanian comma decimals`() {
        assertEquals(17.50, p("17,50")!!, 1e-9)
        assertEquals(2.4, p("2,4")!!, 1e-9)
        assertEquals(0.5, p("0,5")!!, 1e-9)
    }

    @Test
    fun `anglo dot decimals`() {
        assertEquals(17.50, p("17.50")!!, 1e-9)
        assertEquals(14.2, p("14.2")!!, 1e-9)
    }

    @Test
    fun `lone separator with three digits is grouping`() {
        assertEquals(1234.0, p("1.234")!!, 1e-9)
        assertEquals(1234.0, p("1,234")!!, 1e-9)
    }

    @Test
    fun `both separators - the later one is the decimal point`() {
        assertEquals(1234.56, p("1.234,56")!!, 1e-9)
        assertEquals(1234.56, p("1,234.56")!!, 1e-9)
        assertEquals(1234567.89, p("1.234.567,89")!!, 1e-9)
    }

    @Test
    fun `repeated separator is always grouping`() {
        assertEquals(1234567.0, p("1.234.567")!!, 1e-9)
        assertEquals(1234567.0, p("1,234,567")!!, 1e-9)
    }

    @Test
    fun `pulls the number out of real currency strings`() {
        assertEquals(17.5, p("17,50 lei")!!, 1e-9)
        assertEquals(14.2, p("€14.20")!!, 1e-9)
        assertEquals(32.5, p("RON 32,50")!!, 1e-9)
        assertEquals(8.4, p("  8,4 km  ")!!, 1e-9)
    }

    @Test
    fun `handles thin and non-breaking spaces used as grouping`() {
        assertEquals(1234.5, p("1 234,5")!!, 1e-9)
        assertEquals(1234.5, p("1 234,5")!!, 1e-9)
    }

    @Test
    fun `negatives survive`() {
        assertEquals(-12.5, p("-12,50")!!, 1e-9)
    }

    @Test
    fun `no number means null, not zero`() {
        assertNull(p(""))
        assertNull(p("   "))
        assertNull(p("Accept"))
        assertNull(p(null))
    }

    @Test
    fun `formatting is terse enough for a small HUD`() {
        assertEquals("17.5 RON", NumberParsing.formatMoney(17.50, "RON"))
        assertEquals("18 RON", NumberParsing.formatMoney(18.0, "RON"))
        assertEquals("2.35", NumberParsing.formatRate(2.3456))
        assertEquals("42", NumberParsing.formatRate(41.6, 0))
    }
}

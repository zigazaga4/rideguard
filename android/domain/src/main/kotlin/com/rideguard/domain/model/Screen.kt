package com.rideguard.domain.model

import kotlinx.serialization.Serializable

/**
 * Plain rectangle in screen pixels. Deliberately NOT android.graphics.Rect —
 * this module must stay Android-free so it can be tested on the JVM.
 */
@Serializable
data class Bounds(
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
) {
    val width: Int get() = right - left
    val height: Int get() = bottom - top
    val centerX: Int get() = (left + right) / 2
    val centerY: Int get() = (top + bottom) / 2
    val area: Int get() = maxOf(0, width) * maxOf(0, height)

    companion object {
        val EMPTY = Bounds(0, 0, 0, 0)
    }
}

/**
 * One run of text on screen, with where it sits.
 *
 * Produced identically by every [com.rideguard.domain.parse.ScreenSource]:
 *  - the AccessibilityService fills [viewId] and leaves [confidence] at 1.0
 *  - the OCR source leaves [viewId] null and sets a real [confidence]
 *
 * Everything downstream is blind to which one produced it. That is the whole
 * point of the abstraction.
 */
@Serializable
data class TextBlock(
    val text: String,
    val bounds: Bounds = Bounds.EMPTY,
    val viewId: String? = null,
    val confidence: Float = 1f,
) {
    /**
     * Rough proxy for font size. The accessibility tree does not expose text
     * size, but a taller node almost always means bigger type — which is how
     * we tell the headline fare from the small print.
     */
    val glyphHeight: Int get() = bounds.height
}

/** One reading of the screen, from any source. */
@Serializable
data class ScreenSnapshot(
    val packageName: String,
    val blocks: List<TextBlock>,
    val capturedAtMs: Long,
) {
    /** All text joined in reading order — handy for logging and regex fallbacks. */
    val flatText: String by lazy {
        blocks.joinToString(separator = "\n") { it.text }
    }

    /** Blocks sorted top-to-bottom, then left-to-right. Reading order. */
    val inReadingOrder: List<TextBlock> by lazy {
        blocks.sortedWith(compareBy({ it.bounds.top }, { it.bounds.left }))
    }

    fun isEmpty(): Boolean = blocks.none { it.text.isNotBlank() }
}

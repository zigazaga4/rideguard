package com.rideguard.overlay

import kotlin.math.roundToInt

/**
 * Where the HUD sits, and — more importantly — where it is NOT allowed to sit.
 *
 * ## Why the forbidden zone exists
 *
 * Android lets a view set `filterTouchesWhenObscured="true"`, and the system
 * then SILENTLY DISCARDS any touch that arrives while another window overlaps
 * that view. Uber is known to use this on the offer card. The failure mode is
 * brutal: the driver taps Accept, nothing happens, the offer expires, and he
 * blames this app — correctly.
 *
 * Both Bolt and Uber put the offer card and its Accept button in the lower
 * portion of the screen, with the map above. So we clamp the HUD out of the
 * bottom band entirely, over the map, where it also happens to be easiest to
 * read.
 *
 * The window is `FLAG_NOT_TOUCHABLE` as well, so this is belt and braces — but
 * the belt is worth keeping. Staying off the Accept button costs nothing and
 * removes any argument about which windows the platform counts as obscuring.
 */
data class OverlayPosition(val x: Int, val y: Int) {
    companion object {
        val UNSET = OverlayPosition(Int.MIN_VALUE, Int.MIN_VALUE)
    }

    val isSet: Boolean get() = this != UNSET
}

object OverlayBounds {

    /**
     * Fraction of screen height, measured from the bottom, that the HUD may
     * never enter. Covers the offer card and Accept/Decline on both apps with
     * room to spare.
     */
    const val FORBIDDEN_BOTTOM_FRACTION = 0.34f

    /** Keep clear of the status bar / notch region too. */
    const val TOP_INSET_FRACTION = 0.03f

    /** Minimum visible sliver, so a stale saved x can never park it off-screen. */
    private const val MIN_VISIBLE_PX = 48

    /**
     * Clamp a desired position into the safe band.
     *
     * @param screenH full display height in pixels
     * @param viewW   measured HUD width; 0 before first layout
     */
    fun clamp(
        x: Int,
        y: Int,
        viewW: Int,
        viewH: Int,
        screenW: Int,
        screenH: Int,
    ): OverlayPosition {
        val topLimit = (screenH * TOP_INSET_FRACTION).roundToInt()
        val bottomLimit = (screenH * (1f - FORBIDDEN_BOTTOM_FRACTION)).roundToInt() - viewH

        val safeBottom = if (bottomLimit < topLimit) topLimit else bottomLimit

        val minX = -(viewW - MIN_VISIBLE_PX).coerceAtLeast(0)
        val maxX = (screenW - MIN_VISIBLE_PX).coerceAtLeast(0)

        return OverlayPosition(
            x = x.coerceIn(minX, maxX),
            y = y.coerceIn(topLimit, safeBottom),
        )
    }

    /**
     * Where the HUD goes: upper area, inset from the left. Sits over the map on
     * both driver apps, well clear of the card.
     */
    fun defaultFor(screenW: Int, screenH: Int): OverlayPosition = OverlayPosition(
        x = (screenW * 0.04f).roundToInt(),
        y = (screenH * 0.10f).roundToInt(),
    )
}

/**
 * How far the driver may scale the HUD, and why not further.
 *
 * Below [MIN] the type stops being legible at a glance in a moving car, which
 * is the only thing this HUD is for. Above [MAX] a HUD placed low enough can
 * reach into the forbidden bottom band whatever [OverlayBounds] does, because
 * that band is clamped against the view height and the view height is what
 * scaling changes.
 *
 * Mirrored as plain constants in `:data`'s `SettingsRepository`; the two
 * modules do not depend on each other, and both clamp independently so a stale
 * saved value cannot get through either door.
 */
object OverlayScale {
    const val MIN = 0.7f
    const val MAX = 2.0f
    const val DEFAULT = 1.0f

    fun clamp(value: Float): Float =
        if (value.isNaN()) DEFAULT else value.coerceIn(MIN, MAX)
}

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
 * bottom band entirely. The driver can still drag it anywhere else.
 *
 * This is not a nicety. It is the difference between an app that works and an
 * app that costs its user money.
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

    /** Minimum visible sliver so the HUD can never be dragged off-screen. */
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
     * Where a fresh install puts the HUD: upper area, inset from the left.
     * Sits over the map on both driver apps, well clear of the card.
     */
    fun defaultFor(screenW: Int, screenH: Int): OverlayPosition = OverlayPosition(
        x = (screenW * 0.04f).roundToInt(),
        y = (screenH * 0.10f).roundToInt(),
    )
}

package com.rideguard.domain.parse

import com.rideguard.domain.model.ScreenSnapshot
import kotlinx.coroutines.flow.Flow

/**
 * Anything that can produce readings of the screen.
 *
 * This is the seam the whole architecture hangs on. Three implementations
 * exist, and NOTHING downstream can tell them apart:
 *
 *  - `AccessibilitySource`  — the view tree. Fast, structured, battery-cheap.
 *                             Primary on the sideload flavour.
 *  - `ProjectionOcrSource`  — MediaProjection + ML Kit. Sees anything, costs
 *                             more. Required for the Play Store flavour,
 *                             since Play rejects accessibility use for this.
 *  - `ReplaySource`         — recorded JSON fixtures. Turns parser work into
 *                             ordinary JVM unit testing, with no device, no
 *                             permissions and no sitting in a parked car at
 *                             2am waiting for a ride request.
 *
 * That third one is not a testing afterthought. It is why `:domain` is a pure
 * Kotlin module, and it is the reason parser development is pleasant instead
 * of miserable.
 */
interface ScreenSource {
    val id: String

    /** Readings, already debounced by the implementation where it is cheap to do so. */
    val snapshots: Flow<ScreenSnapshot>

    fun start()
    fun stop()
}

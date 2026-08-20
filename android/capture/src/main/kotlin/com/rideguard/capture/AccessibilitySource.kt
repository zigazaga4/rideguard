package com.rideguard.capture

import com.rideguard.domain.model.ScreenSnapshot
import com.rideguard.domain.parse.ScreenSource
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * The primary reader on the sideload flavour.
 *
 * The [AccessibilityService][android.accessibilityservice.AccessibilityService]
 * pushes readings in via [submit]; the pipeline consumes [snapshots]. Keeping
 * the source separate from the service means the pipeline never holds a
 * reference to a system service component, so nothing leaks when Android
 * tears the service down and rebuilds it.
 *
 * Why this path is the right default here:
 *  - The view tree gives structured text in single-digit milliseconds, which
 *    matters when the driver has ~10-15 seconds to decide.
 *  - Filtering by package in `accessibility_service_config.xml` means zero
 *    work happens outside Bolt and Uber. Battery-neutral when idle.
 *  - An AccessibilityService is system-bound, so it needs no foreground
 *    notification and does not get killed like an ordinary service.
 *  - Overlays added from inside it can use `TYPE_ACCESSIBILITY_OVERLAY`,
 *    which needs no "draw over other apps" grant and — critically — cannot
 *    be suppressed by an app calling `Window.setHideOverlayWindows(true)`.
 */
class AccessibilitySource : ScreenSource {

    override val id: String = "accessibility"

    private val _snapshots = MutableSharedFlow<ScreenSnapshot>(
        replay = 0,
        extraBufferCapacity = 8,
        // Under a burst of events the newest reading is the only one that
        // matters; never suspend the service thread waiting for a consumer.
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    override val snapshots: Flow<ScreenSnapshot> = _snapshots.asSharedFlow()

    @Volatile
    private var running = false

    override fun start() {
        running = true
    }

    override fun stop() {
        running = false
    }

    /** Called from the accessibility service on its own thread. Never blocks. */
    fun submit(snapshot: ScreenSnapshot) {
        if (!running) return
        _snapshots.tryEmit(snapshot)
    }

    companion object {
        /**
         * Shared instance. The service and the pipeline live in different
         * lifecycles and must meet somewhere; a small explicit singleton is
         * clearer here than wiring a DI graph through a system service.
         */
        val shared = AccessibilitySource()
    }
}

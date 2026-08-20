package com.rideguard.overlay

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.WindowManager
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.platform.ComposeView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.lifecycle.setViewTreeViewModelStoreOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import com.rideguard.domain.model.OfferEconomics

/**
 * A Compose view living in a `WindowManager` window, floating over other apps.
 *
 * ## The two things that make this work
 *
 * **1. The window takes no input at all.** `FLAG_NOT_FOCUSABLE` keeps it from
 * stealing keyboard focus from the driver app; `FLAG_NOT_TOUCHABLE` keeps it
 * from consuming a single touch. See [buildParams] — this is a safety
 * property, not a styling choice.
 *
 * **2. The window type is chosen, not assumed.** When we are running inside
 * an AccessibilityService we use `TYPE_ACCESSIBILITY_OVERLAY`, which:
 *   - needs no `SYSTEM_ALERT_WINDOW` grant (one fewer scary permission screen), and
 *   - **cannot be suppressed** by an app calling `Window.setHideOverlayWindows(true)`,
 *     an API available since Android 12 that force-hides every ordinary
 *     `TYPE_APPLICATION_OVERLAY`. If Bolt or Uber ever switch that on, an
 *     ordinary overlay simply vanishes. An accessibility overlay does not,
 *     because suppressing those would break the phone for disabled users.
 *
 * ## Compose in a raw window
 *
 * A `ComposeView` outside an Activity has no lifecycle owner, no saved-state
 * registry and no ViewModel store, and it hard-crashes on attach without all
 * three. [OverlayViewOwner] supplies them.
 */
class OverlayHost(
    private val context: Context,
    /** True when constructed from an AccessibilityService. See class doc. */
    private val useAccessibilityOverlayType: Boolean,
) {

    private val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val owner = OverlayViewOwner()
    private val mainHandler = Handler(Looper.getMainLooper())

    private val state = mutableStateOf(OverlayUiState())
    private var composeView: ComposeView? = null
    private var params: WindowManager.LayoutParams? = null
    private var attached = false

    /** Where the HUD currently sits, already clamped into the safe band. */
    var position: OverlayPosition = OverlayPosition.UNSET
        private set

    // ---------------------------------------------------------------- public

    /**
     * Everything below hops to the main thread first.
     *
     * This is not defensive padding — it is load-bearing. Constructing a
     * `ComposeView`, driving a `LifecycleRegistry` and calling
     * `WindowManager.addView` are all main-thread-only, and `LifecycleRegistry`
     * throws outright when touched from anywhere else. The pipeline that feeds
     * this class runs its parsing and maths off the main thread by design, so
     * without this hop a perfectly reasonable caller takes down a resident
     * system-bound service and Android disables it.
     *
     * Owning the threading requirement here rather than trusting every caller
     * to remember it is the difference between a subtle recurring crash and a
     * class that is simply safe to call.
     */
    fun show(economics: OfferEconomics) = onMain {
        state.value = state.value.copy(economics = economics, visible = true)
        attachIfNeeded()
    }

    fun hide() = onMain {
        state.value = state.value.copy(visible = false)
        detach()
    }

    /**
     * Clamped on the way in, not trusted as given.
     *
     * A position saved on another handset, another orientation or before a
     * display-size change can name a spot that no longer exists — or, worse,
     * one that now sits over the Accept button. [OverlayBounds] is the only
     * thing standing between a stale preference and a HUD parked on top of the
     * control the driver needs.
     */
    fun setPosition(next: OverlayPosition) = onMain {
        if (next.isSet) {
            val (screenW, screenH) = screenSize()
            val view = composeView
            position = OverlayBounds.clamp(
                x = next.x,
                y = next.y,
                viewW = view?.width ?: 0,
                viewH = view?.height ?: 0,
                screenW = screenW,
                screenH = screenH,
            )
            params?.let { p ->
                p.x = position.x
                p.y = position.y
                if (attached) runCatching { windowManager.updateViewLayout(composeView, p) }
            }
        }
    }

    fun destroy() = onMain {
        detach()
        owner.destroy()
    }

    private inline fun onMain(crossinline block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            mainHandler.post { block() }
        }
    }

    // --------------------------------------------------------------- private

    @SuppressLint("InflateParams")
    private fun attachIfNeeded() {
        if (attached) return

        // The ENTIRE attach is guarded, not just addView.
        //
        // Creating the ComposeView, wiring the ViewTree owners and moving the
        // LifecycleRegistry can each throw, and this runs inside a system-bound
        // AccessibilityService — an escaping exception there does not just lose
        // the HUD, it kills the service and Android switches it off, which the
        // user sees as "app keeps stopping" with no way back except re-enabling
        // it by hand. A missing overlay is recoverable; a dead service is not.
        try {
            val metrics = screenSize()
            if (!position.isSet) {
                position = OverlayBounds.defaultFor(metrics.first, metrics.second)
            }

            val layoutParams = buildParams(position)
            val view = ComposeView(context).apply {
                setViewTreeLifecycleOwner(owner)
                setViewTreeSavedStateRegistryOwner(owner)
                setViewTreeViewModelStoreOwner(owner)
                setContent { OverlayHud(state = state.value) }
            }

            owner.create()
            windowManager.addView(view, layoutParams)
            composeView = view
            params = layoutParams
            attached = true
            owner.resume()
            Log.i(TAG, "Overlay attached at (${position.x}, ${position.y})")
        } catch (t: Throwable) {
            // Commonly a missing overlay permission on the non-accessibility
            // path, or a bad window token after a display change.
            Log.e(TAG, "Could not add overlay window", t)
            attached = false
            composeView = null
            params = null
            runCatching { owner.destroy() }
        }
    }

    private fun detach() {
        val view = composeView ?: return
        attached = false
        runCatching { windowManager.removeViewImmediate(view) }
            .onFailure { Log.w(TAG, "Overlay already detached", it) }
        composeView = null
        params = null
        owner.stop()
    }

    /**
     * NOT_FOCUSABLE never steals keyboard focus from the driver app.
     *
     * NOT_TOUCHABLE is the important one, and it is a safety fix rather than a
     * simplification. A touchable window sitting over a driver app is a window
     * that can eat a tap meant for Accept — either by swallowing it outright,
     * or by tripping the receiving view's `filterTouchesWhenObscured`, which
     * makes Android discard the touch silently with no feedback whatsoever. The
     * driver taps, nothing happens, the offer expires, and he blames this app.
     * Correctly.
     *
     * With this flag the HUD is inert: every touch passes straight through to
     * whatever is underneath. Nothing in the HUD may become interactive again
     * without reopening that failure mode.
     */
    private fun buildParams(at: OverlayPosition) = WindowManager.LayoutParams(
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.WRAP_CONTENT,
        windowType(),
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
            WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        x = at.x
        y = at.y
    }

    private fun windowType(): Int = when {
        useAccessibilityOverlayType ->
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY

        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O ->
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY

        else ->
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
    }

    private fun screenSize(): Pair<Int, Int> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val b = windowManager.currentWindowMetrics.bounds
            b.width() to b.height()
        } else {
            @Suppress("DEPRECATION")
            val d = windowManager.defaultDisplay
            @Suppress("DEPRECATION")
            (d.width to d.height)
        }

    private companion object {
        const val TAG = "OverlayHost"
    }
}

/**
 * Supplies the three ViewTree owners a `ComposeView` requires when it lives
 * outside an Activity. Without all three, attaching the view crashes.
 */
internal class OverlayViewOwner : SavedStateRegistryOwner, ViewModelStoreOwner {

    private val lifecycleRegistry = LifecycleRegistry(this)
    private val savedStateController = SavedStateRegistryController.create(this)

    override val lifecycle: Lifecycle get() = lifecycleRegistry
    override val savedStateRegistry: SavedStateRegistry get() = savedStateController.savedStateRegistry
    override val viewModelStore: ViewModelStore = ViewModelStore()

    fun create() {
        if (lifecycleRegistry.currentState == Lifecycle.State.INITIALIZED) {
            savedStateController.performRestore(null)
        }
        lifecycleRegistry.currentState = Lifecycle.State.CREATED
    }

    fun resume() {
        lifecycleRegistry.currentState = Lifecycle.State.RESUMED
    }

    fun stop() {
        if (lifecycleRegistry.currentState != Lifecycle.State.DESTROYED) {
            lifecycleRegistry.currentState = Lifecycle.State.CREATED
        }
    }

    fun destroy() {
        lifecycleRegistry.currentState = Lifecycle.State.DESTROYED
        viewModelStore.clear()
    }
}

/** Everything the HUD renders from. Flat and pre-computed on purpose. */
data class OverlayUiState(
    val economics: OfferEconomics? = null,
    val visible: Boolean = false,
)

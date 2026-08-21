package com.rideguard.service

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import com.rideguard.capture.AccessibilitySource
import com.rideguard.capture.AccessibilityTreeReader
import com.rideguard.capture.OfferRecorder
import com.rideguard.data.SettingsRepository
import com.rideguard.domain.model.Platform
import com.rideguard.domain.pipeline.OfferEvent
import com.rideguard.domain.pipeline.OfferPipeline
import com.rideguard.overlay.OverlayHost
import com.rideguard.overlay.OverlayPosition
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch

/**
 * The resident reader.
 *
 * ## Why this is an AccessibilityService and not a foreground service
 *
 * An AccessibilityService is bound by the system. It does not need a
 * persistent notification, it is not subject to the usual background limits,
 * and Android restarts it for us. It also gets us
 * `TYPE_ACCESSIBILITY_OVERLAY`, which needs no overlay permission and cannot
 * be suppressed by `Window.setHideOverlayWindows(true)`.
 *
 * ## What keeps it cheap
 *
 * `accessibility_service_config.xml` restricts delivery to Bolt, Uber and the
 * mock harness. Outside those packages this method is never called at all —
 * no wakeups, no tree walks, no battery cost. That single attribute is worth
 * more than any optimisation inside this class.
 */
class RideGuardAccessibilityService : AccessibilityService() {

    // Main dispatcher, deliberately.
    //
    // This scope's collectors touch the overlay, and every one of those calls
    // must land on the main thread. The expensive part — parsing the screen and
    // running the maths — is pushed off main with `flowOn` below, so we get the
    // correct thread for UI without doing real work on it.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val source = AccessibilitySource.shared
    private val pipeline = OfferPipeline()

    private lateinit var settings: SettingsRepository
    private lateinit var recorder: OfferRecorder

    private var overlay: OverlayHost? = null
    private var currentPlatform: Platform = Platform.UNKNOWN

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.i(TAG, "Connected — watching ${Platform.watchedPackages}")

        settings = SettingsRepository(this)
        recorder = OfferRecorder(this)
        source.start()

        overlay = OverlayHost(
            context = this,
            // We are inside an AccessibilityService, so take the overlay type
            // that needs no permission and cannot be hidden by the host app.
            useAccessibilityOverlayType = true,
        )

        // Persist wherever and however large the driver leaves it, against the
        // platform whose card was last on screen.
        overlay?.onLayoutCommitted = { pos, scale ->
            scope.launch {
                settings.saveHudLayout(currentPlatform, pos.x, pos.y, scale)
                // Clear the flag too, or Done ends the mode on screen while the
                // stored state still says "adjusting" — and the next time the
                // service starts, the driver gets a sample card he never asked
                // for, over whatever app he is in.
                settings.setHudAdjustMode(false)
            }
        }

        // The driver taps "Place the HUD" in the app; the app flips this flag;
        // this service owns the window and acts on it. No new IPC — both sides
        // already read this store.
        scope.launch {
            settings.hudAdjustMode.collect { adjusting ->
                overlay?.setAdjusting(adjusting)
            }
        }

        scope.launch {
            recorder.enabled = settings.recordModeEnabled.first()
        }

        scope.launch {
            settings.recordModeEnabled.collect { recorder.enabled = it }
        }

        scope.launch {
            pipeline.run(source.snapshots, settings.settings)
                // Parse + calculate off the main thread; collect on it.
                .flowOn(Dispatchers.Default)
                .catch { t -> Log.e(TAG, "Pipeline failed", t) }
                .collect { event -> handle(event) }
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val pkg = event?.packageName?.toString() ?: return

        // Reading the tree can throw if the window vanishes underneath us
        // mid-walk, which happens constantly as cards animate in and out.
        val snapshot = try {
            AccessibilityTreeReader.read(
                root = rootInActiveWindow,
                packageName = pkg,
                capturedAtMs = System.currentTimeMillis(),
            )
        } catch (t: Throwable) {
            Log.w(TAG, "Tree read failed for $pkg", t)
            return
        }

        if (snapshot.isEmpty()) return

        // Throttled diagnostics. Without this the only way to tell "the service
        // never fired" from "it fired but parsed nothing" is guesswork, and
        // those two have completely different fixes.
        val now = System.currentTimeMillis()
        if (now - lastLogAtMs > LOG_INTERVAL_MS) {
            lastLogAtMs = now
            Log.d(TAG, "event pkg=$pkg blocks=${snapshot.blocks.size}")
            Log.v(TAG, "text=${snapshot.flatText.replace('\n', '|').take(400)}")
        }

        currentPlatform = Platform.fromPackage(pkg).takeIf { it != Platform.UNKNOWN } ?: currentPlatform
        recorder.record(snapshot)
        source.submit(snapshot)
    }

    override fun onInterrupt() {
        overlay?.hide()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        teardown()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        teardown()
        super.onDestroy()
    }

    // --------------------------------------------------------------- private

    private suspend fun handle(event: OfferEvent) {
        when (event) {
            is OfferEvent.Show -> {
                val e = event.economics
                Log.i(
                    TAG,
                    "SHOW ${e.offer.platform} fare=${e.offer.fare} ${e.currency} " +
                        "km=${e.totalKm} net=${e.net} verdict=${e.verdict} " +
                        "confidence=${e.offer.parseConfidence}",
                )
                restorePositionFor(e.offer.platform)
                overlay?.show(e)
            }

            OfferEvent.Hide -> {
                Log.d(TAG, "HIDE")
                overlay?.hide()
            }
        }
    }

    /**
     * Bolt and Uber lay out differently, so each has its own stored spot AND
     * its own stored size. `OverlayHost` clamps both on the way in, so a
     * geometry saved on another handset, another orientation, or by an older
     * build cannot park the HUD over the Accept button or blow it up past the
     * screen.
     */
    private suspend fun restorePositionFor(platform: Platform) {
        if (platform == currentPlatform && overlay?.position?.isSet == true) return
        currentPlatform = platform
        settings.hudPosition(platform).first()?.let { (x, y) ->
            overlay?.setPosition(OverlayPosition(x, y))
        }
        overlay?.setScale(settings.hudScale(platform).first())
    }

    private fun teardown() {
        source.stop()
        overlay?.destroy()
        overlay = null
        scope.cancel()
        Log.i(TAG, "Torn down")
    }

    @Volatile
    private var lastLogAtMs = 0L

    private companion object {
        const val TAG = "RideGuardA11y"
        const val LOG_INTERVAL_MS = 1_000L
    }
}

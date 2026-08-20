package com.rideguard.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager
import com.rideguard.MainActivity
import com.rideguard.R
import com.rideguard.capture.ProjectionOcrSource
import com.rideguard.data.SettingsRepository
import com.rideguard.domain.pipeline.OfferEvent
import com.rideguard.domain.pipeline.OfferPipeline
import com.rideguard.overlay.OverlayHost
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch

/**
 * Foreground service that owns the MediaProjection capture path.
 *
 * This is the `play` flavour's reader. One service owns BOTH the capture and
 * the overlay so they share a single lifecycle — that is what guarantees no
 * orphaned VirtualDisplay and no leaked window view when Android tears us
 * down.
 *
 * ## The Android 14 ordering rule
 *
 * `startForeground()` with `FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION` must
 * happen BEFORE `getMediaProjection()`. Calling them the other way round
 * throws `SecurityException` on API 34+. That is why the notification goes up
 * first, unconditionally, before we touch the projection at all.
 */
class ProjectionCaptureService : Service() {

    // Main dispatcher — the collector below touches the overlay, which is
    // main-thread-only. OCR and parsing are pushed off main with `flowOn`.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private var projection: MediaProjection? = null
    private var source: ProjectionOcrSource? = null
    private var overlay: OverlayHost? = null

    /**
     * The OCR path sees pixels, not package names, so it cannot know which
     * app is in front. The mock harness and both driver apps all render their
     * platform identity on screen, and the parser registry works it out from
     * the text — this is only a hint for snapshot labelling.
     */
    @Volatile
    private var foregroundPackage: String = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // MUST be first. See class doc.
        startForegroundCompat()

        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, 0) ?: 0
        val data = intent?.let {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                it.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                it.getParcelableExtra(EXTRA_RESULT_DATA)
            }
        }

        if (resultCode == 0 || data == null) {
            Log.e(TAG, "Missing projection consent payload — stopping")
            stopSelf()
            return START_NOT_STICKY
        }

        startCapture(resultCode, data)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        source?.stop()
        overlay?.destroy()
        projection?.stop()
        scope.cancel()
        super.onDestroy()
    }

    // --------------------------------------------------------------- private

    private fun startCapture(resultCode: Int, data: Intent) {
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val mp = manager.getMediaProjection(resultCode, data) ?: run {
            Log.e(TAG, "getMediaProjection returned null")
            stopSelf()
            return
        }

        mp.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                Log.i(TAG, "Projection stopped by system or user")
                stopSelf()
            }
        }, null)
        projection = mp

        val metrics = displayMetrics()
        val ocr = ProjectionOcrSource(
            projection = mp,
            screenWidth = metrics.widthPixels,
            screenHeight = metrics.heightPixels,
            densityDpi = metrics.densityDpi,
            currentPackageProvider = { foregroundPackage },
        )
        source = ocr

        overlay = OverlayHost(
            context = this,
            // No accessibility service on this flavour, so we fall back to
            // TYPE_APPLICATION_OVERLAY and the SYSTEM_ALERT_WINDOW grant.
            useAccessibilityOverlayType = false,
        )

        val settings = SettingsRepository(this)
        val pipeline = OfferPipeline()

        ocr.start()
        scope.launch {
            pipeline.run(ocr.snapshots, settings.settings)
                .flowOn(Dispatchers.Default)
                .catch { t -> Log.e(TAG, "Pipeline failed", t) }
                .collect { event ->
                    when (event) {
                        is OfferEvent.Show -> overlay?.show(event.economics)
                        OfferEvent.Hide -> overlay?.hide()
                    }
                }
        }
    }

    private fun startForegroundCompat() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Screen reading", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while RideGuard is reading ride offers"
                    setShowBadge(false)
                },
            )
        }

        val tap = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )

        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.capture_notification_title))
            .setContentText(getString(R.string.capture_notification_text))
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentIntent(tap)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun displayMetrics(): DisplayMetrics {
        val metrics = DisplayMetrics()
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = wm.currentWindowMetrics.bounds
            metrics.widthPixels = bounds.width()
            metrics.heightPixels = bounds.height()
            metrics.densityDpi = resources.configuration.densityDpi
        } else {
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(metrics)
        }
        return metrics
    }

    companion object {
        private const val TAG = "ProjectionCapture"
        private const val CHANNEL_ID = "rideguard_capture"
        private const val NOTIFICATION_ID = 4711

        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_RESULT_DATA = "result_data"

        fun intent(context: Context, resultCode: Int, data: Intent) =
            Intent(context, ProjectionCaptureService::class.java).apply {
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_RESULT_DATA, data)
            }
    }
}

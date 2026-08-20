package com.rideguard

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.rideguard.service.ProjectionCaptureService
import com.rideguard.ui.RideGuardTheme
import com.rideguard.ui.onboarding.OnboardingScreen
import com.rideguard.ui.settings.SettingsScreen
import com.rideguard.ui.update.UpdateScreen
import com.rideguard.update.UpdateController

class MainActivity : ComponentActivity() {

    /**
     * MediaProjection consent, `play` flavour only.
     *
     * Android 14+ requires fresh consent for every capture session — there is
     * no silent resume after a reboot or a kill, so the UX has to assume this
     * dialog reappears rather than treating it as one-time setup.
     */
    private val projectionConsent = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            ContextCompat.startForegroundService(
                this,
                ProjectionCaptureService.intent(this, result.resultCode, result.data!!),
            )
        }
    }

    private val notificationPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { /* Best-effort: the reader still works without it on the sideload build. */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !Permissions.notificationsGranted(this)) {
            notificationPermission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
        }

        val settings = (application as RideGuardApp).settings

        // Scoped to the activity, not to a composable: a 60 MB download must
        // survive a rotation. Tying it to composition would restart the
        // download every time the screen recreated.
        val updates = UpdateController(applicationContext, lifecycleScope)

        setContent {
            RideGuardTheme {
                val onboarded by settings.isOnboarded.collectAsState(initial = null)
                var forceOnboarding by remember { mutableStateOf(false) }
                var showUpdates by remember { mutableStateOf(false) }

                when {
                    // null means DataStore has not answered yet. Rendering
                    // onboarding during that gap would flash the setup flow
                    // at an existing user on every cold start.
                    onboarded == null -> Unit

                    forceOnboarding || onboarded == false -> OnboardingScreen(
                        settings = settings,
                        onFinished = {
                            forceOnboarding = false
                            if (!BuildConfig.USE_ACCESSIBILITY) requestProjection()
                        },
                    )

                    showUpdates -> UpdateScreen(
                        controller = updates,
                        onBack = { showUpdates = false },
                    )

                    else -> SettingsScreen(
                        settings = settings,
                        onReplayOnboarding = { forceOnboarding = true },
                        onOpenUpdates = { showUpdates = true },
                    )
                }
            }
        }
    }

    private fun requestProjection() {
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        projectionConsent.launch(manager.createScreenCaptureIntent())
    }
}

/** Convenience for the OCR flavour, used from the settings screen. */
fun Context.startProjectionConsent(launch: (Intent) -> Unit) {
    val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
    launch(manager.createScreenCaptureIntent())
}

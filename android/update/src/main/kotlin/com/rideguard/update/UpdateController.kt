package com.rideguard.update

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.pm.PackageInfoCompat
import com.rideguard.domain.update.AndroidRelease
import com.rideguard.domain.update.UpdateCheck
import com.rideguard.domain.update.UpdateStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File

/** Everything the update screen needs to render, and nothing it does not. */
sealed interface UpdateUiState {
    data object Idle : UpdateUiState
    data object Checking : UpdateUiState

    data object UpToDate : UpdateUiState

    data class Available(
        val release: AndroidRelease,
        val notes: String?,
        val mandatory: Boolean,
    ) : UpdateUiState

    data class Downloading(
        val release: AndroidRelease,
        val bytesRead: Long,
        val totalBytes: Long?,
    ) : UpdateUiState {
        /** Null when the server never declared a length — show a spinner, not a lie. */
        val fraction: Float?
            get() = totalBytes?.takeIf { it > 0 }?.let { (bytesRead.toDouble() / it).toFloat() }
    }

    /** Downloaded; the system dialog is up or about to be. */
    data class Installing(val release: AndroidRelease) : UpdateUiState

    /**
     * Recoverable. [retryable] separates "the network blipped, tap again" from
     * "this will never work until you change something", so the UI can offer
     * the right button.
     */
    data class Failed(val message: String, val retryable: Boolean = true) : UpdateUiState
}

/**
 * Drives the whole update flow: check, download, verify, install.
 *
 * Deliberately explicit rather than automatic. This app runs on a phone
 * someone is working from — replacing it without being asked, mid-shift,
 * because a manifest changed, is not a feature. Every state transition here
 * happens because the driver tapped something.
 */
class UpdateController(
    private val context: Context,
    private val scope: CoroutineScope,
) {

    private val _state = MutableStateFlow<UpdateUiState>(UpdateUiState.Idle)
    val state: StateFlow<UpdateUiState> = _state.asStateFlow()

    private var work: Job? = null

    /** This build's version code, straight from the installed package. */
    val currentVersionCode: Long = runCatching {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        PackageInfoCompat.getLongVersionCode(info)
    }.getOrDefault(0L)

    val currentVersionName: String = runCatching {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName
    }.getOrNull() ?: "unknown"

    init {
        // The install result arrives on a broadcast, long after install()
        // returned. Without this the screen would sit on "Installing" forever
        // when the user declines the system dialog.
        scope.launch {
            ApkInstaller.outcomes.collect { outcome ->
                when (outcome) {
                    is InstallOutcome.Success -> _state.value = UpdateUiState.UpToDate
                    is InstallOutcome.Cancelled -> _state.value = UpdateUiState.Idle
                    is InstallOutcome.Failed ->
                        _state.value = UpdateUiState.Failed(outcome.message, retryable = true)
                    is InstallOutcome.AwaitingUser -> Unit // already reflected
                }
            }
        }
    }

    fun check() {
        work?.cancel()
        work = scope.launch {
            _state.value = UpdateUiState.Checking

            val raw = UpdateNetwork.fetchText(UpdateCheck.MANIFEST_URL).getOrElse { error ->
                _state.value = UpdateUiState.Failed(
                    "Couldn't reach GitHub to check for updates. " +
                        (error.message ?: "No connection."),
                )
                return@launch
            }

            _state.value = when (
                val status = UpdateCheck.evaluate(
                    raw = raw,
                    currentVersionCode = currentVersionCode.toInt(),
                    deviceSdk = Build.VERSION.SDK_INT,
                )
            ) {
                is UpdateStatus.UpToDate -> UpdateUiState.UpToDate

                is UpdateStatus.Available -> UpdateUiState.Available(
                    release = status.release,
                    notes = status.notes,
                    mandatory = status.mandatory,
                )

                is UpdateStatus.TooOldToUnderstand -> UpdateUiState.Failed(
                    "This build is too old to read the update file. " +
                        "Download the latest APK from GitHub by hand.",
                    retryable = false,
                )

                is UpdateStatus.Unsupported -> UpdateUiState.Failed(status.reason, retryable = false)

                is UpdateStatus.Unreadable -> UpdateUiState.Failed(status.reason)
            }
        }
    }

    /** Downloads, verifies the digest, then hands off to the system installer. */
    fun downloadAndInstall(release: AndroidRelease) {
        work?.cancel()
        work = scope.launch {
            _state.value = UpdateUiState.Downloading(release, 0, release.sizeBytes)

            val target = File(context.cacheDir, "rideguard-${release.versionCode}.apk")

            val digest = UpdateNetwork.download(release.url, target) { read, total ->
                _state.value = UpdateUiState.Downloading(release, read, total ?: release.sizeBytes)
            }.getOrElse { error ->
                _state.value = UpdateUiState.Failed(
                    "Download failed. " + (error.message ?: "Check your connection."),
                )
                return@launch
            }

            // Verified BEFORE the file is handed to the installer, not after.
            // A mismatch here means we did not get the artifact that was
            // published — a CDN serving something stale, a truncated body, or
            // worse — and the only safe move is to delete it and stop.
            val expected = release.sha256?.lowercase()
            if (expected != null && !digest.equals(expected, ignoreCase = true)) {
                target.delete()
                _state.value = UpdateUiState.Failed(
                    "The downloaded file doesn't match what was published, so it wasn't installed. " +
                        "Try again, and if it keeps happening install from GitHub by hand.",
                    retryable = true,
                )
                return@launch
            }

            if (!canInstallUnknownApps()) {
                _state.value = UpdateUiState.Failed(
                    "Android needs your permission to install apps from RideGuard. " +
                        "Allow it on the next screen, then tap Install again.",
                    retryable = false,
                )
                return@launch
            }

            _state.value = UpdateUiState.Installing(release)

            ApkInstaller(context).install(target).onFailure { error ->
                _state.value = UpdateUiState.Failed(
                    "Couldn't start the install. " + (error.message ?: ""),
                )
            }
        }
    }

    fun cancel() {
        work?.cancel()
        _state.value = UpdateUiState.Idle
    }

    /**
     * Android 8+ gates "install unknown apps" per source app rather than with
     * one global switch, so this has to be checked for US specifically.
     */
    fun canInstallUnknownApps(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    /** The settings page that grants the above. */
    fun unknownSourcesIntent(): Intent =
        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
            .setData(Uri.parse("package:${context.packageName}"))

    /** Fallback when everything else fails: the releases page, in a browser. */
    fun releasesPageIntent(): Intent =
        Intent(Intent.ACTION_VIEW, Uri.parse(RELEASES_URL))

    /** Clears finished downloads so a 60 MB APK is not kept forever. */
    fun clearCache() {
        runCatching {
            context.cacheDir.listFiles { f -> f.name.startsWith("rideguard-") && f.extension == "apk" }
                ?.forEach { it.delete() }
        }
    }

    companion object {
        const val RELEASES_URL = "https://github.com/zigazaga4/rideguard/releases"
    }
}

/** True when this build was installed by a store, in which case let the store update it. */
fun Context.wasInstalledByStore(): Boolean = runCatching {
    val installer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        packageManager.getInstallSourceInfo(packageName).installingPackageName
    } else {
        @Suppress("DEPRECATION")
        packageManager.getInstallerPackageName(packageName)
    }
    installer == "com.android.vending"
}.getOrDefault(false)

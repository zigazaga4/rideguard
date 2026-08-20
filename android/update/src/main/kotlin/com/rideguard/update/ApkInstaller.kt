package com.rideguard.update

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import java.io.File

/** What the system installer eventually said. */
sealed interface InstallOutcome {
    /** The confirmation dialog is up; the user has not answered yet. */
    data object AwaitingUser : InstallOutcome
    data object Success : InstallOutcome
    data class Failed(val message: String) : InstallOutcome
    data object Cancelled : InstallOutcome
}

/**
 * Hands a downloaded APK to the system installer.
 *
 * Uses the `PackageInstaller` session API rather than the older
 * `ACTION_VIEW`/`ACTION_INSTALL_PACKAGE` intent. The session API takes the APK
 * as a stream we write into, which means no `FileProvider`, no exported
 * content URI, and no `FLAG_GRANT_READ_URI_PERMISSION` dance — the file never
 * has to be made readable to another process at all. It also reports back a
 * real status code instead of leaving us guessing whether the user cancelled.
 */
class ApkInstaller(private val context: Context) {

    /**
     * Writes [apk] into a new install session and commits it.
     *
     * Returns as soon as the session is committed — the actual result arrives
     * asynchronously on [outcomes], because the user still has a system dialog
     * to answer and that can take as long as he likes.
     */
    fun install(apk: File): Result<Unit> = runCatching {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_FULL_INSTALL,
        ).apply {
            setAppPackageName(context.packageName)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Skip the "app installed, open it?" screen where the platform
                // allows. The driver came from our own update screen; he does
                // not need to be told twice.
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_UNSPECIFIED)
            }
        }

        val sessionId = installer.createSession(params)
        installer.openSession(sessionId).use { session ->
            session.openWrite(SESSION_NAME, 0, apk.length()).use { output ->
                apk.inputStream().use { input -> input.copyTo(output) }
                session.fsync(output)
            }

            val intent = Intent(context, InstallResultReceiver::class.java).apply {
                action = InstallResultReceiver.ACTION
            }
            // MUTABLE is required: the platform fills this PendingIntent in
            // with the status extras. An immutable one gets delivered empty and
            // the install appears to hang forever.
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
            val pending = PendingIntent.getBroadcast(context, sessionId, intent, flags)

            session.commit(pending.intentSender)
        }
    }

    companion object {
        private const val SESSION_NAME = "rideguard-update"

        /**
         * Install results, from the system's own broadcast.
         *
         * Replay of 1 so a screen that rotates, or is recreated between the
         * user tapping "Install" and the system answering, still learns the
         * outcome rather than sitting on a spinner forever.
         */
        internal val _outcomes = MutableSharedFlow<InstallOutcome>(replay = 1, extraBufferCapacity = 4)
        val outcomes: SharedFlow<InstallOutcome> = _outcomes
    }
}

/**
 * Receives the installer's verdict.
 *
 * The important case is [PackageInstaller.STATUS_PENDING_USER_ACTION]: the
 * system does not put its own confirmation dialog up for us, it hands back an
 * Intent and expects us to launch it. Miss that and the install silently never
 * happens, with no error anywhere — a genuinely miserable thing to debug.
 */
class InstallResultReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return

        when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                }
                if (confirm == null) {
                    emit(InstallOutcome.Failed("The installer asked for confirmation but sent no dialog"))
                    return
                }
                // We are a receiver, not an activity, so there is no task to
                // launch into without this flag.
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                runCatching { context.startActivity(confirm) }
                    .onSuccess { emit(InstallOutcome.AwaitingUser) }
                    .onFailure { emit(InstallOutcome.Failed("Could not open the install dialog")) }
            }

            PackageInstaller.STATUS_SUCCESS -> emit(InstallOutcome.Success)

            PackageInstaller.STATUS_FAILURE_ABORTED -> emit(InstallOutcome.Cancelled)

            else -> {
                val raw = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                Log.w(TAG, "Install failed: status=$status message=$raw")
                emit(InstallOutcome.Failed(explain(status, raw)))
            }
        }
    }

    /**
     * Turns installer status codes into something a driver can act on.
     *
     * The conflict case matters most and is the one people lose hours to: an
     * APK signed with a different key than the copy already installed cannot
     * replace it, by design. The message has to say "uninstall first", because
     * the raw text the platform supplies does not.
     */
    private fun explain(status: Int, raw: String?): String = when (status) {
        PackageInstaller.STATUS_FAILURE_CONFLICT ->
            "This update was signed with a different key than the copy you have installed. " +
                "Uninstall RideGuard, then install this version — settings will be lost."

        PackageInstaller.STATUS_FAILURE_STORAGE ->
            "Not enough free space to install the update."

        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE ->
            "This build is not compatible with this phone."

        PackageInstaller.STATUS_FAILURE_INVALID ->
            "The downloaded file is not a valid APK. Try checking for updates again."

        PackageInstaller.STATUS_FAILURE_BLOCKED ->
            "Android blocked the install. Allow RideGuard to install unknown apps, then retry."

        else -> raw?.takeIf { it.isNotBlank() } ?: "The install failed (code $status)."
    }

    private fun emit(outcome: InstallOutcome) {
        ApkInstaller._outcomes.tryEmit(outcome)
    }

    companion object {
        private const val TAG = "RideGuardInstall"
        const val ACTION = "com.rideguard.update.INSTALL_RESULT"
    }
}

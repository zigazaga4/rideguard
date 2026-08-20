package com.rideguard.domain.update

import kotlinx.serialization.json.Json

/**
 * Decides what to do about a fetched [UpdateManifest].
 *
 * Pure: no networking, no Android, no clock. Everything that could fail lives
 * in the caller, so every rule in here is testable on the JVM in milliseconds
 * and the Swift side can mirror it exactly. Two implementations that disagree
 * about what "newer" means is precisely the bug that ships a downgrade.
 */
object UpdateCheck {

    /** The highest [UpdateManifest.schemaVersion] this build understands. */
    const val SUPPORTED_SCHEMA = 1

    /** Where the manifest lives. Kept here so both platforms cite one source. */
    const val MANIFEST_URL =
        "https://raw.githubusercontent.com/zigazaga4/rideguard/main/updates/latest.json"

    /**
     * Lenient on purpose. `ignoreUnknownKeys` is what lets a future release
     * add a field without bricking every copy of the app already in the wild —
     * the one failure mode an updater absolutely cannot have, since a broken
     * updater cannot ship its own fix.
     */
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    /** Parses a manifest, or returns null. Never throws. */
    fun parse(raw: String): UpdateManifest? =
        runCatching { json.decodeFromString(UpdateManifest.serializer(), raw) }.getOrNull()

    /**
     * @param currentVersionCode this build's `BuildConfig.VERSION_CODE`
     * @param deviceSdk `Build.VERSION.SDK_INT`
     */
    fun evaluate(
        manifest: UpdateManifest,
        currentVersionCode: Int,
        deviceSdk: Int,
    ): UpdateStatus {
        // Checked before anything is read out of the payload: if the format
        // moved on without us, we do not get to interpret its contents.
        if (manifest.schemaVersion > SUPPORTED_SCHEMA) {
            return UpdateStatus.TooOldToUnderstand(manifest.schemaVersion)
        }

        // No Android block is not an error — a release may be iOS-only.
        val release = manifest.android ?: return UpdateStatus.UpToDate

        if (release.versionCode <= currentVersionCode) return UpdateStatus.UpToDate

        if (release.minSdk > deviceSdk) {
            return UpdateStatus.Unsupported(
                "${release.versionName} needs Android API ${release.minSdk}; " +
                    "this phone is on $deviceSdk",
            )
        }

        // A manifest that points nowhere usable is a publishing mistake, and
        // saying so beats handing an unusable URL to the downloader.
        if (!release.url.startsWith("https://")) {
            return UpdateStatus.Unreadable("Release URL is not HTTPS")
        }

        return UpdateStatus.Available(
            release = release,
            notes = manifest.notes,
            mandatory = manifest.mandatory,
        )
    }

    /** Convenience for the common fetch-then-decide path. */
    fun evaluate(raw: String, currentVersionCode: Int, deviceSdk: Int): UpdateStatus {
        val manifest = parse(raw)
            ?: return UpdateStatus.Unreadable("Update manifest could not be read")
        return evaluate(manifest, currentVersionCode, deviceSdk)
    }

    /**
     * Human-readable size. Deliberately coarse — the driver is deciding
     * whether to spend mobile data, not auditing bytes.
     */
    fun formatSize(bytes: Long?): String? {
        if (bytes == null || bytes <= 0) return null
        val mb = bytes.toDouble() / (1024.0 * 1024.0)
        return if (mb >= 10) "${mb.toInt()} MB" else String.format(java.util.Locale.US, "%.1f MB", mb)
    }
}

package com.rideguard.domain.update

import kotlinx.serialization.Serializable

/**
 * The update manifest, published to GitHub and read by both platforms.
 *
 * This app is distributed outside both stores — sideloaded on Android,
 * ad-hoc-signed on iOS — so nothing is going to tap the driver on the
 * shoulder when a new build exists. This file is that shoulder tap. It lives
 * at a stable raw URL on the repo:
 *
 *     https://raw.githubusercontent.com/zigazaga4/rideguard/main/updates/latest.json
 *
 * A raw URL rather than the GitHub Releases API on purpose: no rate limit
 * worth worrying about, no auth, no pagination, and the shape is ours rather
 * than GitHub's, so it cannot change under us.
 *
 * ## Rules that both platforms MUST implement identically
 *
 * 1. Both platform blocks are OPTIONAL. Shipping an Android-only release is
 *    normal, and an iPhone reading that manifest must conclude "nothing for
 *    me", never "error".
 * 2. Compare on the INTEGER ([AndroidRelease.versionCode] / [IosRelease.build]).
 *    Display strings are for humans and sort terribly — "1.10.0" is older than
 *    "1.9.0" under every string comparison ever written.
 * 3. Unknown fields are ignored, so adding one later cannot brick an old
 *    client. That is why the decoder sets `ignoreUnknownKeys`.
 * 4. A [schemaVersion] we do not recognise means WE are too old to be reading
 *    this safely — say so and point at a manual download, rather than guessing
 *    at the payload and installing something unexpected.
 * 5. Nothing here is ever fatal. Failing to reach GitHub must not stop a
 *    driver mid-shift; the updater is a convenience and degrades to silence.
 */
@Serializable
data class UpdateManifest(
    val schemaVersion: Int = 1,
    /** ISO-8601 UTC. Display only — never used for ordering. */
    val publishedAt: String? = null,
    /** Short changelog, shown verbatim. May contain newlines. */
    val notes: String? = null,
    /**
     * A release important enough to nag about. It still does not install
     * itself — see [UpdateStatus.Available].
     */
    val mandatory: Boolean = false,
    val android: AndroidRelease? = null,
    val ios: IosRelease? = null,
)

@Serializable
data class AndroidRelease(
    /** The only field ordering is decided on. */
    val versionCode: Int,
    /** Human-facing, e.g. "1.2.0". */
    val versionName: String,
    /** Direct HTTPS link to the APK — a GitHub release asset. */
    val url: String,
    /**
     * Lowercase hex SHA-256 of the APK.
     *
     * Not paranoia: this is served over plain HTTPS from a public repo and
     * then handed to the package installer. Checking the digest before install
     * is the difference between "we downloaded the right file" and "we
     * downloaded a file". Null means unverifiable, which callers should treat
     * as a reason to warn, not as a reason to trust.
     */
    val sha256: String? = null,
    /** For showing "42 MB" before a driver spends his mobile data on it. */
    val sizeBytes: Long? = null,
    /** Refuse to offer a build the device cannot run. */
    val minSdk: Int = 0,
)

@Serializable
data class IosRelease(
    val version: String,
    /** The only field ordering is decided on. */
    val build: Int,
    /**
     * HTTPS URL of the `itms-services` manifest plist.
     *
     * iOS has no API for an app to install an app, so the OTA plist is the
     * whole mechanism. It only works for ad-hoc/enterprise-signed builds, and
     * both this URL and the .ipa it points at must be HTTPS with a valid
     * certificate — GitHub release assets qualify.
     */
    val manifestUrl: String,
    val minIosVersion: String? = null,
)

/** What the app should do about [UpdateManifest], once compared to itself. */
sealed interface UpdateStatus {

    /** Already current. The common case, and it should be silent. */
    data object UpToDate : UpdateStatus

    /**
     * A newer build exists.
     *
     * Deliberately NOT self-installing. This runs on a working phone during a
     * shift; deciding on the driver's behalf to replace the app while he is
     * waiting for a ride is not a convenience, it is an outage.
     */
    data class Available(
        val release: AndroidRelease,
        val notes: String?,
        val mandatory: Boolean,
    ) : UpdateStatus

    /** The manifest is newer than this build knows how to read. */
    data class TooOldToUnderstand(val manifestSchema: Int) : UpdateStatus

    /** A newer build exists but this device cannot run it. */
    data class Unsupported(val reason: String) : UpdateStatus

    /** Network failure, garbage JSON, whatever. Non-fatal by construction. */
    data class Unreadable(val reason: String) : UpdateStatus
}

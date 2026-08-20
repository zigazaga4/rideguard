package com.rideguard.domain

import com.rideguard.domain.update.UpdateCheck
import com.rideguard.domain.update.UpdateStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The updater is the one component that cannot ship its own fix.
 *
 * If a bug here makes the app refuse every update, or crash while checking,
 * the only remedy is walking the user through a manual sideload — which is
 * exactly the thing this feature exists to avoid. So the rules get pinned
 * down hard, especially the failure paths, which are the ones nobody
 * exercises by hand.
 */
class UpdateCheckTest {

    private val sdk = 35

    private fun manifest(
        schema: Int = 1,
        versionCode: Int = 2,
        minSdk: Int = 26,
        url: String = "https://github.com/zigazaga4/rideguard/releases/download/v1.1.0/app.apk",
    ) = """
        {
          "schemaVersion": $schema,
          "publishedAt": "2026-08-20T17:00:00Z",
          "notes": "Bolt fares are read as net now.",
          "mandatory": false,
          "android": {
            "versionCode": $versionCode,
            "versionName": "1.1.0",
            "url": "$url",
            "sha256": "abc123",
            "sizeBytes": 61973326,
            "minSdk": $minSdk
          },
          "ios": { "version": "1.1.0", "build": 2, "manifestUrl": "https://example.com/m.plist" }
        }
    """.trimIndent()

    @Test
    fun `a newer build is offered`() {
        val status = UpdateCheck.evaluate(manifest(versionCode = 2), currentVersionCode = 1, deviceSdk = sdk)
        assertTrue(status is UpdateStatus.Available)
        assertEquals("1.1.0", (status as UpdateStatus.Available).release.versionName)
    }

    @Test
    fun `the same build is not offered`() {
        assertEquals(
            UpdateStatus.UpToDate,
            UpdateCheck.evaluate(manifest(versionCode = 2), currentVersionCode = 2, deviceSdk = sdk),
        )
    }

    @Test
    fun `an older build is never offered as a downgrade`() {
        assertEquals(
            UpdateStatus.UpToDate,
            UpdateCheck.evaluate(manifest(versionCode = 2), currentVersionCode = 7, deviceSdk = sdk),
        )
    }

    @Test
    fun `ordering uses the integer, not the display string`() {
        // "1.10.0" sorts BEFORE "1.9.0" under every string comparison there
        // is, which is precisely why versionName must never decide this.
        val raw = """
            {"schemaVersion":1,"android":{"versionCode":10,"versionName":"1.10.0",
             "url":"https://x/y.apk","minSdk":26}}
        """.trimIndent()
        val status = UpdateCheck.evaluate(raw, currentVersionCode = 9, deviceSdk = sdk)
        assertTrue("1.10.0 must be newer than 1.9.0", status is UpdateStatus.Available)
    }

    @Test
    fun `an iOS-only release is silence on Android, not an error`() {
        val iosOnly = """
            {"schemaVersion":1,"ios":{"version":"1.1.0","build":2,
             "manifestUrl":"https://example.com/m.plist"}}
        """.trimIndent()
        assertEquals(
            UpdateStatus.UpToDate,
            UpdateCheck.evaluate(iosOnly, currentVersionCode = 1, deviceSdk = sdk),
        )
    }

    @Test
    fun `a build the phone cannot run is refused with a reason`() {
        val status = UpdateCheck.evaluate(
            manifest(versionCode = 5, minSdk = 34),
            currentVersionCode = 1,
            deviceSdk = 30,
        )
        assertTrue(status is UpdateStatus.Unsupported)
        assertTrue((status as UpdateStatus.Unsupported).reason.contains("34"))
    }

    @Test
    fun `a manifest from the future is admitted to rather than guessed at`() {
        val status = UpdateCheck.evaluate(manifest(schema = 99), currentVersionCode = 1, deviceSdk = sdk)
        assertEquals(UpdateStatus.TooOldToUnderstand(99), status)
    }

    @Test
    fun `the schema check happens before the payload is trusted`() {
        // A future schema may legitimately redefine what these fields mean.
        // Reading them anyway is how an updater installs the wrong artifact.
        val weird = """
            {"schemaVersion":2,"android":{"versionCode":999,"versionName":"9.9.9",
             "url":"https://x/y.apk","minSdk":26}}
        """.trimIndent()
        assertTrue(
            UpdateCheck.evaluate(weird, currentVersionCode = 1, deviceSdk = sdk)
                is UpdateStatus.TooOldToUnderstand,
        )
    }

    @Test
    fun `garbage never throws`() {
        for (junk in listOf("", "   ", "not json at all", "{", "[]", "null", "<html>404</html>")) {
            val status = UpdateCheck.evaluate(junk, currentVersionCode = 1, deviceSdk = sdk)
            assertTrue("$junk should be Unreadable, was $status", status is UpdateStatus.Unreadable)
        }
    }

    @Test
    fun `unknown fields are ignored so a future release cannot brick old clients`() {
        val withExtras = """
            {"schemaVersion":1,"somethingNew":{"nested":true},"notes":"hi",
             "android":{"versionCode":3,"versionName":"1.2.0","url":"https://x/y.apk",
                        "minSdk":26,"futureField":42}}
        """.trimIndent()
        val status = UpdateCheck.evaluate(withExtras, currentVersionCode = 1, deviceSdk = sdk)
        assertTrue(status is UpdateStatus.Available)
    }

    @Test
    fun `a non-HTTPS release URL is rejected rather than handed to the installer`() {
        val status = UpdateCheck.evaluate(
            manifest(url = "http://github.com/insecure.apk"),
            currentVersionCode = 1,
            deviceSdk = sdk,
        )
        assertTrue(status is UpdateStatus.Unreadable)
    }

    @Test
    fun `notes and mandatory ride along to the UI`() {
        val raw = """
            {"schemaVersion":1,"notes":"Fixes the Bolt commission bug.","mandatory":true,
             "android":{"versionCode":4,"versionName":"1.3.0","url":"https://x/y.apk","minSdk":26}}
        """.trimIndent()
        val status = UpdateCheck.evaluate(raw, currentVersionCode = 1, deviceSdk = sdk) as UpdateStatus.Available
        assertEquals("Fixes the Bolt commission bug.", status.notes)
        assertTrue(status.mandatory)
    }

    @Test
    fun `sizes are formatted for a driver deciding about mobile data`() {
        assertEquals("59 MB", UpdateCheck.formatSize(61_973_326))
        assertEquals("1.5 MB", UpdateCheck.formatSize(1_572_864))
        assertNull(UpdateCheck.formatSize(null))
        assertNull(UpdateCheck.formatSize(0))
    }
}

package com.rideguard.capture

import android.content.Context
import android.util.Log
import com.rideguard.domain.model.ScreenSnapshot
import com.rideguard.domain.parse.FixtureCodec
import com.rideguard.domain.parse.FixtureBundle
import com.rideguard.domain.parse.OfferFixture
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/**
 * Record mode. Dumps every candidate offer card to disk as a JSON fixture.
 *
 * BUILD THIS FIRST, USE IT FIRST. Before tuning a single regex, run a shift
 * with recording on. You come back with real Bolt and Uber cards — surge,
 * normal, short, long, and the weird ones — and from then on the parser is
 * developed on the JVM against them with instant feedback.
 *
 * Writes one file per capture rather than one growing bundle, so a crash mid
 * shift never costs more than the last card. [exportBundle] merges them.
 */
class OfferRecorder(
    context: Context,
    private val maxFiles: Int = 500,
) {
    private val appContext = context.applicationContext
    private val counter = AtomicInteger(0)

    @Volatile
    var enabled: Boolean = false

    private val dir: File by lazy {
        File(appContext.getExternalFilesDir(null) ?: appContext.filesDir, DIR_NAME).apply { mkdirs() }
    }

    /** Where the driver can find the files to send you. Shown in settings. */
    val exportPath: String get() = dir.absolutePath

    fun record(snapshot: ScreenSnapshot, label: String? = null) {
        if (!enabled) return
        if (snapshot.isEmpty()) return

        try {
            if (countFiles() >= maxFiles) {
                Log.w(TAG, "Recording cap of $maxFiles reached — stopping to protect storage")
                enabled = false
                return
            }

            val n = counter.incrementAndGet()
            val safePkg = snapshot.packageName.substringAfterLast('.').ifBlank { "unknown" }
            val file = File(dir, "offer_${snapshot.capturedAtMs}_${safePkg}_$n.json")

            val fixture = OfferFixture(
                label = label ?: "$safePkg #$n",
                snapshot = snapshot,
                note = "Auto-recorded. Fill in `expected` by hand to turn this into a test.",
            )
            file.writeText(FixtureCodec.encode(FixtureBundle(fixtures = listOf(fixture))))
        } catch (t: Throwable) {
            // Recording is a development aid. It must never take the service
            // down with it, whatever the storage state.
            Log.e(TAG, "Failed to record snapshot", t)
        }
    }

    /** Merge every recorded file into one bundle for sending off the device. */
    fun exportBundle(): File? = try {
        val fixtures = dir.listFiles { f -> f.extension == "json" && f.name.startsWith("offer_") }
            ?.sortedBy { it.name }
            ?.flatMap { file ->
                runCatching { FixtureCodec.decode(file.readText()).fixtures }.getOrDefault(emptyList())
            }
            .orEmpty()

        if (fixtures.isEmpty()) {
            null
        } else {
            File(dir, EXPORT_NAME).apply {
                writeText(FixtureCodec.encode(FixtureBundle(fixtures = fixtures)))
            }
        }
    } catch (t: Throwable) {
        Log.e(TAG, "Failed to export fixture bundle", t)
        null
    }

    fun clear() {
        dir.listFiles()?.forEach { it.delete() }
        counter.set(0)
    }

    fun countFiles(): Int = dir.listFiles()?.count { it.extension == "json" } ?: 0

    private companion object {
        const val TAG = "OfferRecorder"
        const val DIR_NAME = "fixtures"
        const val EXPORT_NAME = "rideguard-fixtures.json"
    }
}

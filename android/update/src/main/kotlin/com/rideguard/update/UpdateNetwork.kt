package com.rideguard.update

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlin.coroutines.coroutineContext

/**
 * The two network calls the updater makes: read a small JSON manifest, and
 * stream down an APK.
 *
 * Both are written against `HttpURLConnection` rather than a client library —
 * see the note in this module's build file. Both are also cancellable: a
 * driver who backs out of a 60 MB download on mobile data must actually stop
 * paying for it, so the copy loop checks the coroutine on every chunk instead
 * of only at the end.
 */
internal object UpdateNetwork {

    private const val CONNECT_TIMEOUT_MS = 15_000
    private const val READ_TIMEOUT_MS = 30_000
    private const val BUFFER = 64 * 1024

    /** Bytes downloaded so far, and the total if the server declared one. */
    fun interface ProgressListener {
        fun onProgress(bytesRead: Long, totalBytes: Long?)
    }

    /**
     * Fetches the manifest as text.
     *
     * `no-cache` is deliberate: `raw.githubusercontent.com` sits behind a CDN,
     * and a driver who taps "check again" after being told about a release
     * should not be served the stale copy that predates it.
     */
    suspend fun fetchText(url: String): Result<String> = withContext(Dispatchers.IO) {
        runCatching {
            val connection = open(url)
            connection.setRequestProperty("Cache-Control", "no-cache")
            connection.setRequestProperty("Accept", "application/json")
            try {
                val code = connection.responseCode
                if (code !in 200..299) throw IOException("HTTP $code")
                connection.inputStream.bufferedReader().use { it.readText() }
            } finally {
                connection.disconnect()
            }
        }
    }

    /**
     * Streams [url] into [destination], returning the lowercase hex SHA-256 of
     * what actually arrived.
     *
     * The digest is computed during the copy rather than by re-reading the
     * finished file: this runs on a phone, the payload is tens of megabytes,
     * and a second full pass over storage buys nothing.
     */
    suspend fun download(
        url: String,
        destination: File,
        progress: ProgressListener,
    ): Result<String> = withContext(Dispatchers.IO) {
        runCatching {
            val connection = open(url)
            try {
                val code = connection.responseCode
                if (code !in 200..299) throw IOException("HTTP $code")

                val declared = connection.contentLengthLong.takeIf { it > 0 }
                val digest = MessageDigest.getInstance("SHA-256")
                var total = 0L

                connection.inputStream.use { input ->
                    destination.outputStream().use { output ->
                        val buffer = ByteArray(BUFFER)
                        while (true) {
                            // Cancellation has to be honoured mid-file. Checking
                            // only between requests would let a cancelled 60 MB
                            // download run to completion on the driver's data.
                            coroutineContext.ensureActive()

                            val read = input.read(buffer)
                            if (read < 0) break
                            output.write(buffer, 0, read)
                            digest.update(buffer, 0, read)
                            total += read
                            progress.onProgress(total, declared)
                        }
                        output.flush()
                    }
                }

                if (declared != null && total != declared) {
                    throw IOException("Truncated download: got $total of $declared bytes")
                }

                digest.digest().joinToString("") { "%02x".format(it) }
            } finally {
                connection.disconnect()
            }
        }.onFailure {
            // A half-written APK is worse than none: it would fail to install
            // with a confusing parse error and then sit in the cache looking
            // like a completed download.
            destination.delete()
        }
    }

    private fun open(url: String): HttpURLConnection {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = CONNECT_TIMEOUT_MS
        connection.readTimeout = READ_TIMEOUT_MS
        connection.requestMethod = "GET"
        // GitHub release assets redirect to a signed objects.githubusercontent.com
        // URL. Both hops are HTTPS, which is the only case HttpURLConnection
        // follows automatically — a protocol change would silently return the
        // redirect body instead of the file.
        connection.instanceFollowRedirects = true
        connection.setRequestProperty("User-Agent", "RideGuard-Updater")
        return connection
    }
}

package com.rideguard.capture

import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.rideguard.domain.model.Bounds
import com.rideguard.domain.model.ScreenSnapshot
import com.rideguard.domain.model.TextBlock
import com.rideguard.domain.parse.ScreenSource
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

/**
 * The Play Store reader: screen pixels through on-device OCR.
 *
 * Slower and heavier than the accessibility path, and used because Google
 * Play rejects AccessibilityService use for anything that is not genuine
 * assistive technology. Screen recording carries no such policy problem.
 *
 * ## Performance is the whole game here
 *
 * The driver has ten to fifteen seconds to decide, so the budget from
 * frame-captured to HUD-visible is a few hundred milliseconds. Two decisions
 * do most of the work:
 *
 *  1. **Downscale before OCR.** Running recognition on a full 1080x2400
 *     frame is the single biggest mistake in this design. [scaleFactor]
 *     typically buys a 5-10x speedup with no meaningful accuracy loss on
 *     text this large.
 *  2. **Drop frames rather than queue them.** [inFlight] means a slow OCR
 *     pass never builds a backlog. The newest frame is the only one that
 *     matters; a stale one is worse than none.
 *
 * ## Android 14+ rules that will bite
 *
 *  - The host service MUST already be foreground, with
 *    `foregroundServiceType="mediaProjection"`, BEFORE `getMediaProjection()`.
 *  - Consent is required per session. There is no silent resume after a
 *    reboot or a kill — plan the UX around re-asking.
 *  - `FLAG_SECURE` windows (banking apps) capture as solid black.
 */
class ProjectionOcrSource(
    private val projection: MediaProjection,
    private val screenWidth: Int,
    private val screenHeight: Int,
    private val densityDpi: Int,
    /** Package to stamp on snapshots — the caller tracks the foreground app. */
    private val currentPackageProvider: () -> String,
    /** 0.5 halves each dimension, quartering the pixels OCR must chew through. */
    private val scaleFactor: Float = 0.5f,
    /** Floor on time between OCR passes. Below this you are just burning battery. */
    private val minIntervalMs: Long = 400L,
) : ScreenSource {

    override val id: String = "projection-ocr"

    private val _snapshots = MutableSharedFlow<ScreenSnapshot>(
        replay = 0,
        extraBufferCapacity = 4,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    override val snapshots: Flow<ScreenSnapshot> = _snapshots.asSharedFlow()

    private val recognizer: TextRecognizer =
        TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)

    private val captureWidth = (screenWidth * scaleFactor).roundToInt().coerceAtLeast(1)
    private val captureHeight = (screenHeight * scaleFactor).roundToInt().coerceAtLeast(1)

    private val inFlight = AtomicBoolean(false)
    private var lastProcessedAt = 0L

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var imageReader: ImageReader? = null
    private var virtualDisplay: VirtualDisplay? = null

    override fun start() {
        if (thread != null) return

        val t = HandlerThread("rideguard-capture").apply { start() }
        val h = Handler(t.looper)
        thread = t
        handler = h

        val reader = ImageReader.newInstance(
            captureWidth, captureHeight, PixelFormat.RGBA_8888, /* maxImages = */ 2,
        )
        reader.setOnImageAvailableListener({ onFrame(it) }, h)
        imageReader = reader

        virtualDisplay = projection.createVirtualDisplay(
            "rideguard",
            captureWidth,
            captureHeight,
            densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface,
            null,
            h,
        )

        Log.i(TAG, "Capturing at ${captureWidth}x$captureHeight (from ${screenWidth}x$screenHeight)")
    }

    override fun stop() {
        virtualDisplay?.release()
        virtualDisplay = null
        imageReader?.close()
        imageReader = null
        thread?.quitSafely()
        thread = null
        handler = null
        runCatching { recognizer.close() }
    }

    // --------------------------------------------------------------- private

    private fun onFrame(reader: ImageReader) {
        val image = try {
            reader.acquireLatestImage()
        } catch (t: Throwable) {
            Log.w(TAG, "acquireLatestImage failed", t)
            null
        } ?: return

        val now = System.currentTimeMillis()

        // Throttle, and never let OCR passes overlap. Dropping a frame is
        // always better than falling behind the screen.
        if (now - lastProcessedAt < minIntervalMs || !inFlight.compareAndSet(false, true)) {
            image.close()
            return
        }
        lastProcessedAt = now

        val bitmap = try {
            image.toBitmap()
        } catch (t: Throwable) {
            Log.w(TAG, "Bitmap conversion failed", t)
            null
        } finally {
            image.close()
        }

        if (bitmap == null) {
            inFlight.set(false)
            return
        }

        recognize(bitmap, now)
    }

    private fun recognize(bitmap: Bitmap, capturedAtMs: Long) {
        recognizer.process(InputImage.fromBitmap(bitmap, 0))
            .addOnSuccessListener { result ->
                val inverseScale = 1f / scaleFactor
                val blocks = result.textBlocks.flatMap { block ->
                    block.lines.mapNotNull { line ->
                        val box = line.boundingBox ?: return@mapNotNull null
                        TextBlock(
                            text = line.text,
                            // Map back to real screen coordinates so the
                            // layout heuristics see the geometry they expect.
                            bounds = Bounds(
                                left = (box.left * inverseScale).roundToInt(),
                                top = (box.top * inverseScale).roundToInt(),
                                right = (box.right * inverseScale).roundToInt(),
                                bottom = (box.bottom * inverseScale).roundToInt(),
                            ),
                            viewId = null,
                            confidence = line.confidence ?: 0.8f,
                        )
                    }
                }

                if (blocks.isNotEmpty()) {
                    _snapshots.tryEmit(
                        ScreenSnapshot(
                            packageName = currentPackageProvider(),
                            blocks = blocks,
                            capturedAtMs = capturedAtMs,
                        ),
                    )
                }
            }
            .addOnFailureListener { Log.w(TAG, "OCR failed", it) }
            .addOnCompleteListener {
                bitmap.recycle()
                inFlight.set(false)
            }
    }

    /**
     * ImageReader hands back rows padded to a hardware-friendly stride, so a
     * naive copy produces a skewed image. We allocate to the padded width and
     * then crop back.
     */
    private fun Image.toBitmap(): Bitmap {
        val plane = planes[0]
        val pixelStride = plane.pixelStride
        val rowStride = plane.rowStride
        val rowPadding = rowStride - pixelStride * width

        val padded = Bitmap.createBitmap(
            width + rowPadding / pixelStride,
            height,
            Bitmap.Config.ARGB_8888,
        )
        padded.copyPixelsFromBuffer(plane.buffer)

        return if (rowPadding == 0) {
            padded
        } else {
            Bitmap.createBitmap(padded, 0, 0, width, height).also {
                if (it !== padded) padded.recycle()
            }
        }
    }

    private companion object {
        const val TAG = "ProjectionOcrSource"
    }
}

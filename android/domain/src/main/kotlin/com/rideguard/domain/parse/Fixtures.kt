package com.rideguard.domain.parse

import com.rideguard.domain.model.ScreenSnapshot
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * A recorded offer card, captured on a real device during a real shift.
 *
 * This is the single highest-leverage artefact in the project. One shift with
 * record mode on produces dozens of these across both platforms — surge and
 * normal, short and long, and the malformed edge cases nobody would think to
 * invent. Parser development then happens on the JVM with instant feedback,
 * instead of in a parked car at 2am waiting for a ride request.
 */
@Serializable
data class OfferFixture(
    val label: String,
    val snapshot: ScreenSnapshot,
    /** Filled in by hand after recording, so tests can assert real values. */
    val expected: ExpectedOffer? = null,
    val note: String? = null,
)

/** What a human confirmed the card actually said. */
@Serializable
data class ExpectedOffer(
    val fare: Double? = null,
    val currency: String? = null,
    val pickupKm: Double? = null,
    val pickupMin: Double? = null,
    val tripKm: Double? = null,
    val tripMin: Double? = null,
    val shouldParse: Boolean = true,
)

@Serializable
data class FixtureBundle(
    val version: Int = 1,
    val fixtures: List<OfferFixture> = emptyList(),
)

/** JSON codec for fixtures. Lenient on read so old recordings keep working. */
object FixtureCodec {
    val json = Json {
        prettyPrint = true
        ignoreUnknownKeys = true
        encodeDefaults = true
        isLenient = true
    }

    fun encode(bundle: FixtureBundle): String = json.encodeToString(bundle)
    fun decode(text: String): FixtureBundle = json.decodeFromString(text)

    fun encodeSnapshot(snapshot: ScreenSnapshot): String = json.encodeToString(snapshot)
    fun decodeSnapshot(text: String): ScreenSnapshot = json.decodeFromString(text)
}

/**
 * Replays recorded snapshots as if they were coming off a live screen.
 *
 * Same [ScreenSource] contract as the accessibility and OCR readers, so the
 * entire pipeline — parse, calculate, verdict — runs against it unchanged and
 * with no device, no permissions and no emulator.
 */
class ReplaySource(
    private val snapshotsToReplay: List<ScreenSnapshot>,
    /** Gap between readings. Zero in tests; raise it to eyeball the HUD live. */
    private val intervalMs: Long = 0L,
    private val loop: Boolean = false,
) : ScreenSource {

    override val id: String = "replay"

    @Volatile
    private var running = false

    override val snapshots: Flow<ScreenSnapshot> = flow {
        do {
            for (snapshot in snapshotsToReplay) {
                if (!running) return@flow
                emit(snapshot)
                if (intervalMs > 0) delay(intervalMs)
            }
        } while (loop && running)
    }

    override fun start() {
        running = true
    }

    override fun stop() {
        running = false
    }

    companion object {
        fun fromBundle(bundle: FixtureBundle, intervalMs: Long = 0L): ReplaySource =
            ReplaySource(bundle.fixtures.map { it.snapshot }, intervalMs)

        fun fromJson(text: String, intervalMs: Long = 0L): ReplaySource =
            fromBundle(FixtureCodec.decode(text), intervalMs)
    }
}

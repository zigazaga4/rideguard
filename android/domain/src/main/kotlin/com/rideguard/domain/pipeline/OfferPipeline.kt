package com.rideguard.domain.pipeline

import com.rideguard.domain.calc.ProfitCalculator
import com.rideguard.domain.model.DriverThresholds
import com.rideguard.domain.model.OfferEconomics
import com.rideguard.domain.model.Platform
import com.rideguard.domain.model.RideOffer
import com.rideguard.domain.model.ScreenSnapshot
import com.rideguard.domain.model.VehicleProfile
import com.rideguard.domain.parse.OfferParserRegistry
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapNotNull

/** Everything the pipeline needs from settings, snapshotted at a point in time. */
data class PipelineSettings(
    val vehicle: VehicleProfile = VehicleProfile.DEFAULT_RO,
    val thresholds: DriverThresholds = DriverThresholds(),
    val commissionByPlatform: Map<Platform, Double> = Platform.entries.associateWith { it.defaultCommissionRate },
    val fareIsNetByPlatform: Map<Platform, Boolean> = Platform.entries.associateWith { it.fareShownIsNetByDefault },
) {
    fun commissionFor(p: Platform): Double = commissionByPlatform[p] ?: p.defaultCommissionRate
    fun fareIsNetFor(p: Platform): Boolean = fareIsNetByPlatform[p] ?: p.fareShownIsNetByDefault
}

/** What the overlay reacts to. */
sealed interface OfferEvent {
    data class Show(val economics: OfferEconomics) : OfferEvent
    data object Hide : OfferEvent
}

/**
 * Screen readings in, HUD instructions out.
 *
 * Two things earn their keep here:
 *
 *  - **Debounce.** `onAccessibilityEvent` can fire dozens of times a second
 *    while a card animates in. Parsing every one of those would burn battery
 *    for no benefit, so we settle briefly first.
 *
 *  - **Fingerprint dedupe.** The same offer re-emits constantly as the
 *    countdown ticks. Recomputing identical maths and re-rendering the HUD
 *    would make the overlay flicker under the driver's eyes at exactly the
 *    wrong moment.
 *
 * The debounce window is deliberately short. The driver has roughly ten to
 * fifteen seconds to decide, so the whole path from card-appears to
 * HUD-visible has to stay well inside a few hundred milliseconds.
 */
class OfferPipeline(
    private val registry: OfferParserRegistry = OfferParserRegistry(),
    private val debounceMs: Long = 120L,
) {

    @OptIn(FlowPreview::class, ExperimentalCoroutinesApi::class)
    fun run(
        snapshots: Flow<ScreenSnapshot>,
        settings: Flow<PipelineSettings>,
    ): Flow<OfferEvent> =
        settings.flatMapLatest { current ->
            snapshots
                .debounce(debounceMs)
                .map { snapshot -> snapshot to parse(snapshot, current) }
                .distinctUntilChanged { (_, a), (_, b) -> fingerprint(a) == fingerprint(b) }
                .map { (_, offer) -> toEvent(offer, current) }
                .distinctUntilChanged { a, b -> a is OfferEvent.Hide && b is OfferEvent.Hide }
        }

    /** Single-shot evaluation. Used by manual entry, tests and replay. */
    fun evaluate(offer: RideOffer, settings: PipelineSettings): OfferEconomics? =
        calculatorFor(settings).evaluate(offer)

    private fun parse(snapshot: ScreenSnapshot, settings: PipelineSettings): RideOffer? =
        registry.parse(snapshot) { platform -> settings.fareIsNetFor(platform) }

    private fun toEvent(offer: RideOffer?, settings: PipelineSettings): OfferEvent {
        if (offer == null) return OfferEvent.Hide
        val economics = calculatorFor(settings).evaluate(offer) ?: return OfferEvent.Hide
        return OfferEvent.Show(economics)
    }

    private fun calculatorFor(settings: PipelineSettings) = ProfitCalculator(
        vehicle = settings.vehicle,
        thresholds = settings.thresholds,
        commissionRateFor = { settings.commissionFor(it.platform) },
    )

    /**
     * Identity of an offer for dedupe purposes. Deliberately excludes the
     * countdown and anything else that ticks — otherwise every second would
     * look like a brand new offer and the HUD would strobe.
     */
    private fun fingerprint(offer: RideOffer?): String = offer?.let {
        "${it.platform}|${it.fare}|${it.pickupKm}|${it.tripKm}|${it.pickupMin}|${it.tripMin}"
    } ?: "none"
}

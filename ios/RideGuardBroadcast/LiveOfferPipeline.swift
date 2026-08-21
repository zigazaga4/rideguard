import Foundation
import RideGuardCore

/// Screen readings in, `LiveVerdict`s out.
///
/// The Swift half of `OfferPipeline.kt`, minus the coroutine plumbing: a
/// broadcast extension has one frame at a time on one thread, so the debounce
/// and the flow operators collapse into three pieces of remembered state. What
/// survives verbatim from Android is the part that was learned the hard way —
/// **fingerprint dedupe**. A card that sits on screen for fifteen seconds is
/// re-read forty-odd times, and republishing an identical verdict makes the
/// HUD flicker under the driver's eyes at precisely the moment they are trying
/// to read it.
///
/// Not thread-safe by design. `SampleHandler` drives it synchronously from
/// ReplayKit's callback and nothing else touches it.
final class LiveOfferPipeline {

    /// How many consecutive unreadable frames before the HUD is hidden.
    ///
    /// At the throttle rate in `SampleHandler` this is about a second. One is
    /// too few: a single OCR pass that misses the fare — a finger over the
    /// card, a transition animation — would blink the verdict off in the middle
    /// of a live offer. Many more and a stale verdict lingers over an unrelated
    /// screen long enough to read as a live recommendation.
    private static let hideAfterEmptyFrames = 3

    private let registry = LiveOfferPipeline.makeRegistry()

    private var settings = AppSettings()
    private var calculator = ProfitCalculator(vehicle: .defaultRO, thresholds: DriverThresholds())
    /// False when the App Group is missing, which would mean reading a default
    /// vehicle out of our own container — see `start()`.
    private var enabled = false

    private var sequence: UInt64 = 0
    private var lastFingerprint: String?
    private var emptyFrames = 0
    private var showing = false

    // MARK: - Session

    /// Called on broadcast start and on resume. Re-reads settings both times:
    /// the driver may well have gone to change their fuel price, which is the
    /// one edit that moves every verdict.
    func start() {
        // Without the App Group, `SettingsStore` silently falls back to this
        // process's own defaults — a 7 L/100km petrol car at 7.5 RON/L, for a
        // driver who may be in an EV. That is not a degraded mode, it is
        // confidently wrong numbers, so the pipeline stays inert instead.
        // (`LiveVerdictChannel.publish` would fail for the same reason; this
        // guard makes the failure legible rather than mysterious.)
        enabled = Persistence.isAppGroupAvailable
        guard enabled else { return }

        settings = SettingsStore().load()
        // No commission override: both Romanian cards print the driver's own
        // take, so `Platform.defaultCommissionRate` is zero and there is
        // nothing to subtract. `AppSettings` deliberately has no slider for it.
        calculator = ProfitCalculator(vehicle: settings.vehicle, thresholds: settings.thresholds)

        // Carry on from wherever the last session stopped rather than resetting
        // to zero. The overlay drops anything not newer than what it is already
        // showing, so a restarted counter would have every verdict of this
        // session ignored until it climbed back past the old high-water mark.
        sequence = max(sequence, LiveVerdictChannel.read()?.sequence ?? 0)

        lastFingerprint = nil
        emptyFrames = 0
        showing = false

        // Announce the new session straight away, so an overlay still holding
        // the last session's numbers stops presenting them as live.
        publish(.hidden(sequence: nextSequence()))
    }

    /// Called on pause and on finish. The broadcast is over; there is nothing
    /// true left to say about a card we can no longer see.
    func stop() {
        guard enabled else { return }
        hide()
    }

    // MARK: - Frames

    /// `nil` means the frame could not be read at all, which is treated exactly
    /// like a frame with no offer in it — we did not see a card, so we must not
    /// keep claiming one is there.
    func consume(_ blocks: [TextBlock]?) {
        guard enabled else { return }

        guard let blocks = blocks, let economics = evaluate(blocks) else {
            emptyFrames += 1
            if emptyFrames >= Self.hideAfterEmptyFrames { hide() }
            return
        }

        emptyFrames = 0

        let fingerprint = Self.fingerprint(economics.offer)
        // Republish when the card changed, or when it is unchanged but we had
        // already hidden it — a bad OCR pass mid-offer must be able to bring
        // the same verdict back.
        guard fingerprint != lastFingerprint || !showing else { return }

        lastFingerprint = fingerprint
        showing = true
        publish(Self.verdict(from: economics, sequence: nextSequence()))
    }

    // MARK: - Evaluation

    private func evaluate(_ blocks: [TextBlock]) -> OfferEconomics? {
        // Same join `ScreenSnapshot.flatText` uses, computed before the
        // snapshot exists because the snapshot cannot be built until we know
        // which app this is — and building one twice per frame would sort the
        // blocks into reading order twice for nothing.
        let text = blocks.map(\.text).joined(separator: "\n")
        guard !text.allSatisfy(\.isWhitespace) else { return nil }

        // `strictGuess`, not `guess`. The share extension can afford a fallback
        // — the driver handed it one image on purpose. This process sees the
        // lock screen, the messages app and the bank app too, so a guess is not
        // a fallback here, it is how somebody's account balance becomes a fare.
        // "No idea" has to stay "no idea".
        guard let platform = ScreenshotPlatformGuess.strictGuess(from: text) else { return nil }

        // The package name is the registry's routing key on both platforms.
        // Android reads it off the window; here it is synthesised from what the
        // card says about itself.
        let routed = ScreenSnapshot(
            packageName: platform.packageName,
            blocks: blocks,
            capturedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )

        // The keyword gate is on, and there is no longer any path that turns it
        // off. We are reading the whole phone: the gate plus the
        // money-and-distance check is what stops a receipt, an earnings tab or
        // a banking app from becoming an offer.
        guard let offer = registry.parse(
            routed,
            fareIsNet: { self.settings.fareIsNet(for: $0) }
        ) else { return nil }

        // A missing distance leg is already handled upstream: OfferParser
        // deducts 0.50 of confidence per missing leg, which lands under the
        // calculator's 0.55 threshold and comes back as UNKNOWN. No second
        // guard here — one rule, in one place, shared with Android.
        return calculator.evaluate(offer)
    }

    // MARK: - Publishing

    private func hide() {
        guard showing else { return }
        showing = false
        lastFingerprint = nil
        publish(.hidden(sequence: nextSequence()))
    }

    private func publish(_ verdict: LiveVerdict) {
        LiveVerdictChannel.publish(verdict)
    }

    private func nextSequence() -> UInt64 {
        sequence += 1
        return sequence
    }

    private static func verdict(from economics: OfferEconomics, sequence: UInt64) -> LiveVerdict {
        LiveVerdict(
            sequence: sequence,
            visible: true,
            earningsPerKm: finite(economics.earningsPerKm),
            netPerKm: finite(economics.netPerKm),
            verdict: economics.verdict.rawValue,
            currency: economics.currency,
            totalKm: finite(economics.totalKm),
            netPerHour: economics.netPerHour.map(finite),
            deadheadRatio: economics.deadheadRatio.map(finite),
            // Lower-cased on purpose: `LiveVerdict.platform` is documented as
            // `bolt` / `uber` / `unknown`, while `Platform.rawValue` is the
            // upper-case persistence key.
            platform: economics.offer.platform.rawValue.lowercased(),
            capturedAtMs: economics.offer.capturedAtMs
        )
    }

    /// `JSONEncoder` throws on a non-finite Double and `publish` swallows the
    /// failure, so one NaN would stop the HUD updating for the rest of the
    /// shift with nothing to show for it.
    private static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }

    /// Identity of an offer for dedupe purposes. Excludes the countdown and
    /// anything else that ticks: rebuilding an identical verdict once a second
    /// is what makes the HUD strobe.
    ///
    /// Fixed decimals rather than raw `Double` description so two readings of
    /// the same card that differ only in float noise compare equal.
    private static func fingerprint(_ offer: RideOffer) -> String {
        func leg(_ value: Double?) -> String {
            value.map { String(format: "%.2f", $0) } ?? "-"
        }
        return [
            offer.platform.rawValue,
            String(format: "%.2f", offer.fare),
            leg(offer.pickupKm),
            leg(offer.tripKm),
            leg(offer.pickupMin),
            leg(offer.tripMin),
        ].joined(separator: "|")
    }

    // MARK: - Parsers

    /// The Kotlin keyword lists, verbatim.
    ///
    /// Core's Swift `ParserHints` predates the pass that matched the parsers to
    /// the real Romanian cards and is missing "potrivire" and "numerar" (and
    /// "cerere mare" / "câștig net" per platform). That matters most here:
    /// neither real card says "Acceptă" anywhere, both say `Potrivire`, and
    /// `offerCardHeightFraction` crops away Bolt's `✕ Refuză` pill — so without
    /// these the Bolt gate rests entirely on the word "Bolt" surviving OCR of
    /// one small chip. Delete this the moment Core's list catches up.
    private static func makeRegistry() -> OfferParserRegistry {
        let shared = ParserHints.defaultOfferKeywords + ["potrivire", "numerar"]
        return OfferParserRegistry(parsers: [
            BoltOfferParser(hints: ParserHints(offerKeywords: shared + [
                "bolt", "comandă nouă", "cursă nouă", "cerere mare", "new order", "new ride",
            ])),
            UberOfferParser(hints: ParserHints(offerKeywords: shared + [
                "uber", "câștig net", "exclusive", "match", "surge", "promotion", "include",
            ])),
        ])
    }
}

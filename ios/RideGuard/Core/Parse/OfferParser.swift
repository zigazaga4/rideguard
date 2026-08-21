import Foundation

/// Tunables for the heuristic assembly step.
///
/// These are the knobs to turn once we have real fixtures from a shift. Until
/// then the defaults encode how both Bolt and Uber lay out an offer card:
/// headline fare in the largest type, pickup leg above the paid leg, in
/// reading order.
public struct ParserHints: Sendable {
    /// Pickup distance/time appears ABOVE the trip distance/time on the card.
    public var pickupBeforeTrip: Bool
    /// The fare is the largest text on the card. Nearly always true.
    public var fareIsLargestText: Bool
    /// Sanity clamps — anything outside these is a misread, not a real offer.
    public var minFare: Double
    public var maxFare: Double
    public var maxLegKm: Double
    public var maxLegMinutes: Double
    /// Words that mark this as an offer card rather than any other screen.
    public var offerKeywords: [String]

    public init(
        pickupBeforeTrip: Bool = true,
        fareIsLargestText: Bool = true,
        minFare: Double = 0.5,
        maxFare: Double = 10_000.0,
        maxLegKm: Double = 500.0,
        maxLegMinutes: Double = 600.0,
        offerKeywords: [String] = ParserHints.defaultOfferKeywords
    ) {
        self.pickupBeforeTrip = pickupBeforeTrip
        self.fareIsLargestText = fareIsLargestText
        self.minFare = minFare
        self.maxFare = maxFare
        self.maxLegKm = maxLegKm
        self.maxLegMinutes = maxLegMinutes
        self.offerKeywords = offerKeywords
    }

    /// Multilingual on purpose — Romanian first, since that is the primary
    /// market here, then English. Matching is case-insensitive substring.
    public static let defaultOfferKeywords: [String] = [
        // Romanian. "potrivire" is the accept verb on BOTH real cards —
        // neither Bolt nor Uber says "Acceptă" or "Accept" anywhere in the
        // Romanian build, so without it the gate leans entirely on words that
        // only one of the two happens to show.
        "potrivire", "accept", "acceptă", "refuz", "refuză", "respinge",
        "cursă", "comandă", "preluare", "destinaț", "client", "numerar",
        // English
        "decline", "dismiss", "pickup", "pick up", "dropoff", "drop off",
        "away", "trip", "ride", "fare", "rider", "passenger",
    ]
}

/// Turns a screen reading into a structured offer, or nil if it is not one.
public protocol OfferParser: AnyObject {
    var platform: Platform { get }

    /// Cheap gate — is this even an offer card? Runs before the real work.
    func canParse(_ snapshot: ScreenSnapshot) -> Bool

    /// Full parse. Returns nil when the card cannot be understood.
    func parse(_ snapshot: ScreenSnapshot, fareIsNet: Bool) -> RideOffer?
}

/// Shared assembly logic for every platform.
///
/// Bolt and Uber differ in wording and styling but not in structure: one
/// headline fare, a deadhead leg, and a paid leg, laid out top to bottom.
/// Subclasses override only what genuinely differs, so adding inDrive or
/// Free Now later is one small class, not a new pipeline.
///
/// A class rather than a protocol with a default implementation, because the
/// Kotlin is an abstract class with two overridable members and mirroring it
/// one-for-one keeps the two files diffable against each other.
open class HeuristicOfferParser: OfferParser {
    public let platform: Platform
    public let hints: ParserHints

    public init(platform: Platform, hints: ParserHints = ParserHints()) {
        self.platform = platform
        self.hints = hints
    }

    open func canParse(_ snapshot: ScreenSnapshot) -> Bool {
        if snapshot.isEmpty { return false }
        let tokens = TokenScanner.scan(snapshot)
        let hasMoney = tokens.contains { $0.asMoney != nil }
        let hasDistance = tokens.contains { $0.asDistance != nil }
        if !hasMoney || !hasDistance { return false }

        let haystack = snapshot.flatText.lowercased()
        return hints.offerKeywords.contains { haystack.contains($0) }
    }

    open func parse(_ snapshot: ScreenSnapshot, fareIsNet: Bool) -> RideOffer? {
        let tokens = TokenScanner.scan(snapshot)

        guard let fareToken = pickFare(tokens) else { return nil }
        if fareToken.value < hints.minFare || fareToken.value > hints.maxFare { return nil }

        let distances = tokens.compactMap(\.asDistance)
            .filter { $0.km > 0.0 && $0.km <= hints.maxLegKm }
        let durations = tokens.compactMap(\.asDuration)
            .filter { $0.minutes > 0.0 && $0.minutes <= hints.maxLegMinutes }

        let (pickupKm, tripKm) = assignLegs(distances.map(\.km))
        let (pickupMin, tripMin) = assignLegs(durations.map(\.minutes))

        var confidence: Float = 1.0
        // 0.50, not 0.30, and the exact figure is load-bearing.
        //
        // A missing distance leg means cost gets charged against the paid leg
        // alone, which systematically FLATTERS the offer — the deadhead simply
        // vanishes from the arithmetic. At 0.30 the score lands on 0.60, which
        // is above ProfitCalculator's 0.55 threshold, so the app would render a
        // confident green verdict built on a leg nobody read. 0.50 drops it to
        // 0.50 and it surfaces as UNKNOWN instead.
        //
        // Keep in step with OfferParser.kt. The Kotlin side has tests pinning
        // this; Swift does not yet.
        if pickupKm == nil { confidence -= 0.50 }
        if tripKm == nil { confidence -= 0.50 }
        if pickupMin == nil { confidence -= 0.10 }
        if tripMin == nil { confidence -= 0.10 }
        if distances.count > 3 || durations.count > 3 { confidence -= 0.10 }

        if tripKm == nil && pickupKm == nil { return nil }

        return RideOffer(
            platform: platform,
            fare: fareToken.value,
            currency: fareToken.currency,
            pickupKm: pickupKm,
            pickupMin: pickupMin,
            tripKm: tripKm,
            tripMin: tripMin,
            fareIsNet: fareIsNet,
            surgeMultiplier: tokens.compactMap(\.asMultiplier).first { $0.factor > 1.0 }?.factor,
            passengerRating: tokens.compactMap(\.asRating).first?.stars,
            productName: detectProduct(snapshot),
            pickupAddress: nil,
            destinationAddress: nil,
            capturedAtMs: snapshot.capturedAtMs,
            parseConfidence: min(max(confidence, 0), 1)
        )
    }

    /// The fare is the biggest money on the card. We use text height as a
    /// proxy for font size; when bounds are unavailable (a hand-built snapshot,
    /// or an OCR pass that lost geometry) we fall back to the largest value,
    /// which is the right guess when the card also shows a small bonus line.
    ///
    /// `max(by:)` keeps the FIRST element among equals, which is exactly what
    /// Kotlin's `maxByOrNull` does — the tie-break below depends on it.
    open func pickFare(_ tokens: [Token]) -> Token.Money? {
        let money = tokens.compactMap(\.asMoney)
        if money.isEmpty { return nil }
        if money.count == 1 { return money[0] }

        if hints.fareIsLargestText {
            let tallest = money.max { $0.source.glyphHeight < $1.source.glyphHeight }
            if let tallest, tallest.source.glyphHeight > 0 {
                let ties = money.filter { $0.source.glyphHeight == tallest.source.glyphHeight }
                return ties.max { $0.value < $1.value }
            }
        }
        return money.max { $0.value < $1.value }
    }

    /// Two legs, in reading order: deadhead first, paid leg second.
    ///
    /// With only one value we cannot know which leg it is, so we assign it to
    /// the trip and leave pickup nil — the confidence penalty above makes the
    /// card dim itself rather than quietly assuming a zero-km pickup, which
    /// would flatter the offer exactly when the driver needs the truth.
    open func assignLegs(_ values: [Double]) -> (Double?, Double?) {
        if values.isEmpty { return (nil, nil) }
        if values.count == 1 { return (nil, values[0]) }
        return hints.pickupBeforeTrip ? (values[0], values[1]) : (values[1], values[0])
    }

    /// Product/tier name, e.g. "Comfort", "UberX". Overridden per platform.
    open func detectProduct(_ snapshot: ScreenSnapshot) -> String? { nil }
}

/// Picks the right parser for a snapshot and runs it.
///
/// Adding a platform means adding one entry here — nothing in capture,
/// calculation or presentation changes.
public final class OfferParserRegistry {
    private let parsers: [OfferParser]

    public init(parsers: [OfferParser] = [BoltOfferParser(), UberOfferParser()]) {
        self.parsers = parsers
    }

    public func parser(forPackage packageName: String) -> OfferParser? {
        parsers.first { $0.platform.packageName == packageName }
    }

    public func parser(for platform: Platform) -> OfferParser? {
        parsers.first { $0.platform == platform }
    }

    public func parse(_ snapshot: ScreenSnapshot, fareIsNet: (Platform) -> Bool) -> RideOffer? {
        guard let parser = parser(forPackage: snapshot.packageName) else { return nil }
        guard parser.canParse(snapshot) else { return nil }
        return parser.parse(snapshot, fareIsNet: fareIsNet(parser.platform))
    }

    /// Same as `parse`, but with the keyword gate optional.
    ///
    /// The gate exists on Android because the accessibility service sees EVERY
    /// screen and must not react to the earnings tab. On iOS the only input is
    /// an image the driver deliberately shared, so intent is explicit and a
    /// missing "Acceptă" — cropped off, or OCR'd badly — should not turn into
    /// a silent "not an offer". See `docs/ios-platform-limits.md`.
    public func parse(
        _ snapshot: ScreenSnapshot,
        requireOfferKeywords: Bool,
        fareIsNet: (Platform) -> Bool
    ) -> RideOffer? {
        guard let parser = parser(forPackage: snapshot.packageName) else { return nil }
        if requireOfferKeywords, !parser.canParse(snapshot) { return nil }
        return parser.parse(snapshot, fareIsNet: fareIsNet(parser.platform))
    }
}

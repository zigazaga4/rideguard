import Foundation

/// A ride offer as read off the screen (or typed in by hand). Raw, pre-economics.
///
/// Every field the parser could not find stays nil rather than being guessed.
/// `ProfitCalculator` decides what is survivable — a missing passenger rating
/// is fine, a missing fare is not.
public struct RideOffer: Equatable, Codable, Sendable {
    public let platform: Platform
    /// Fare exactly as displayed on the card.
    public let fare: Double
    public let currency: String
    /// Distance from driver to passenger — the "deadhead" leg.
    public let pickupKm: Double?
    public let pickupMin: Double?
    /// Distance of the paid leg.
    public let tripKm: Double?
    public let tripMin: Double?
    /// Whether `fare` is already net of platform commission. Comes from
    /// settings per-platform, not from the screen.
    public let fareIsNet: Bool
    public let surgeMultiplier: Double?
    public let passengerRating: Double?
    public let productName: String?
    public let pickupAddress: String?
    public let destinationAddress: String?
    public let capturedAtMs: Int64
    /// 0..1 — how much of the card we actually understood. Falls when fields
    /// are missing or ambiguous. The verdict card dims itself below ~0.6
    /// rather than confidently showing a number built on a guess.
    public let parseConfidence: Float

    public init(
        platform: Platform,
        fare: Double,
        currency: String,
        pickupKm: Double?,
        pickupMin: Double?,
        tripKm: Double?,
        tripMin: Double?,
        fareIsNet: Bool,
        surgeMultiplier: Double? = nil,
        passengerRating: Double? = nil,
        productName: String? = nil,
        pickupAddress: String? = nil,
        destinationAddress: String? = nil,
        capturedAtMs: Int64 = 0,
        parseConfidence: Float = 1
    ) {
        self.platform = platform
        self.fare = fare
        self.currency = currency
        self.pickupKm = pickupKm
        self.pickupMin = pickupMin
        self.tripKm = tripKm
        self.tripMin = tripMin
        self.fareIsNet = fareIsNet
        self.surgeMultiplier = surgeMultiplier
        self.passengerRating = passengerRating
        self.productName = productName
        self.pickupAddress = pickupAddress
        self.destinationAddress = destinationAddress
        self.capturedAtMs = capturedAtMs
        self.parseConfidence = parseConfidence
    }

    /// Total distance the car actually moves: deadhead + paid leg.
    public var totalKm: Double? {
        guard let p = pickupKm, let t = tripKm else { return nil }
        return p + t
    }

    /// Total time the driver is committed for.
    public var totalMin: Double? {
        guard let p = pickupMin, let t = tripMin else { return nil }
        return p + t
    }

    /// Enough to do the maths? Distance and fare are mandatory; time is
    /// strongly preferred but we can still show per-km without it.
    public var isComputable: Bool {
        guard fare > 0.0, let km = totalKm else { return false }
        return km > 0.0
    }
}

/// Traffic-light call on an offer.
public enum Verdict: String, Codable, Sendable, CaseIterable {
    /// Clears every threshold.
    case good = "GOOD"
    /// Clears some, misses others. Driver's judgement.
    case marginal = "MARGINAL"
    /// Misses the bar, or actively loses money.
    case bad = "BAD"
    /// Could not read enough of the card to say. Never bluff here.
    case unknown = "UNKNOWN"
}

/// The output of the whole pipeline, and exactly what the verdict card renders.
///
/// Kept flat and pre-computed on purpose: on Android the overlay recomposes
/// under time pressure while the driver has ~10-15 seconds to decide. iOS has
/// no overlay, but the share-extension sheet is under the same clock, so the
/// view should read fields, never calculate.
public struct OfferEconomics: Equatable, Codable, Sendable {
    public let offer: RideOffer
    public let totalKm: Double
    public let totalMin: Double?

    /// Fare before platform commission.
    public let gross: Double
    /// What the platform keeps.
    public let commission: Double
    /// Fuel or electricity for the whole distance, deadhead included.
    public let energyCost: Double
    /// Tyres, servicing, depreciation for the whole distance.
    public let wearCost: Double
    /// What actually lands in the driver's pocket.
    public let net: Double

    public let grossPerKm: Double
    public let grossPerHour: Double?
    public let netPerKm: Double
    public let netPerHour: Double?

    /// pickupKm ÷ tripKm. The pro signal. Nil when either leg is unknown.
    public let deadheadRatio: Double?

    public let verdict: Verdict
    /// Short human reasons the verdict came out this way, for the detail sheet.
    public let reasons: [String]
    public let currency: String

    public init(
        offer: RideOffer,
        totalKm: Double,
        totalMin: Double?,
        gross: Double,
        commission: Double,
        energyCost: Double,
        wearCost: Double,
        net: Double,
        grossPerKm: Double,
        grossPerHour: Double?,
        netPerKm: Double,
        netPerHour: Double?,
        deadheadRatio: Double?,
        verdict: Verdict,
        reasons: [String] = [],
        currency: String
    ) {
        self.offer = offer
        self.totalKm = totalKm
        self.totalMin = totalMin
        self.gross = gross
        self.commission = commission
        self.energyCost = energyCost
        self.wearCost = wearCost
        self.net = net
        self.grossPerKm = grossPerKm
        self.grossPerHour = grossPerHour
        self.netPerKm = netPerKm
        self.netPerHour = netPerHour
        self.deadheadRatio = deadheadRatio
        self.verdict = verdict
        self.reasons = reasons
        self.currency = currency
    }

    /// True when the ride costs more to serve than it pays.
    public var isLossMaking: Bool { net < 0.0 }

    /// Total running cost of serving this ride.
    public var totalCost: Double { energyCost + wearCost }
}

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

    /// Distance we can actually charge cost against: both legs when we have
    /// them, otherwise the paid leg alone.
    ///
    /// Falling back to `tripKm` does understate cost, because it silently
    /// ignores the deadhead — which is why any offer that lands here takes a
    /// heavy `parseConfidence` penalty and surfaces as UNKNOWN rather than as
    /// a confident verdict.
    public var chargeableKm: Double? { totalKm ?? tripKm }

    /// Enough to do the maths? Distance and fare are mandatory; time is
    /// strongly preferred but we can still show per-km without it.
    public var isComputable: Bool {
        fare > 0.0 && (chargeableKm ?? 0.0) > 0.0
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

    /// The verdict in words, for a driver glancing at it for one second.
    ///
    /// This is the ONLY place these four strings exist. They used to be
    /// duplicated in the verdict card and again in the Live Activity, which is
    /// how the app ended up telling the same driver "TAKE IT" on one surface
    /// and nothing at all on another. Colour alone was never enough: about one
    /// man in twelve cannot separate the green from the red, and a HUD glanced
    /// at through a windscreen in daylight is exactly where that bites.
    ///
    /// `unknown` deliberately does not use the word profitable in any form. It
    /// is not a middle verdict — it means the card could not be read, and
    /// saying anything else would be a bluff.
    public var statusLabel: String {
        switch self {
        case .good: return "Profitable"
        case .marginal: return "Semi-profitable"
        case .bad: return "Not profitable"
        case .unknown: return "Can't read it"
        }
    }

    /// One plain line saying what the label is based on. Shown under the label
    /// wherever there is room for it — the driver should never have to guess
    /// what the app measured to arrive at the word.
    public var statusDetail: String {
        switch self {
        case .good: return "Clears all your targets"
        case .marginal: return "Misses one of your targets"
        case .bad: return "Below what you set as worth it"
        case .unknown: return "Not enough of the offer was readable"
        }
    }
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
    /// What actually reaches the driver's hands before running costs —
    /// `gross` minus `commission`. This is the headline the card divides by
    /// distance, because it is the number the driver recognises as "what this
    /// ride pays me".
    public let afterCommission: Double
    /// Fuel or electricity for the whole distance, deadhead included.
    public let energyCost: Double
    /// What actually lands in the driver's pocket.
    public let net: Double

    /// THE HEADLINE NUMBER. Earnings per kilometre driven, commission already
    /// removed but running costs not yet.
    ///
    /// Charged against the FULL distance — pickup plus trip — because that is
    /// how far the car actually moves. This is what the driver compares
    /// between offers, and `netPerKm` sitting directly beneath it shows what
    /// the road takes back.
    public let earningsPerKm: Double

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
        afterCommission: Double,
        energyCost: Double,
        net: Double,
        earningsPerKm: Double,
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
        self.afterCommission = afterCommission
        self.energyCost = energyCost
        self.net = net
        self.earningsPerKm = earningsPerKm
        self.netPerKm = netPerKm
        self.netPerHour = netPerHour
        self.deadheadRatio = deadheadRatio
        self.verdict = verdict
        self.reasons = reasons
        self.currency = currency
    }

    /// True when the ride costs more to serve than it pays.
    public var isLossMaking: Bool { net < 0.0 }

    /// Total running cost of serving this ride. Fuel, on every kilometre.
    public var totalCost: Double { energyCost }

    /// What the road takes out of every kilometre. The gap between the two
    /// headline lines on the card.
    public var costPerKm: Double { totalKm > 0 ? totalCost / totalKm : 0.0 }
}

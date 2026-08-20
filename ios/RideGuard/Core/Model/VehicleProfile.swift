import Foundation

/// How the driver's car burns money. Captured during onboarding — this is the
/// whole reason the app can compute a REAL number instead of a gross fare.
public enum FuelType: String, CaseIterable, Codable, Sendable {
    case petrol = "PETROL"
    case diesel = "DIESEL"
    case lpg = "LPG"
    case hybrid = "HYBRID"
    case electric = "ELECTRIC"

    public var displayName: String {
        switch self {
        case .petrol: return "Petrol"
        case .diesel: return "Diesel"
        case .lpg: return "LPG / GPL"
        case .hybrid: return "Hybrid"
        case .electric: return "Electric"
        }
    }

    /// "L" for liquid fuels, "kWh" for electric. Drives the onboarding copy.
    public var unitLabel: String { self == .electric ? "kWh" : "L" }

    /// "L/100km" or "kWh/100km".
    public var consumptionLabel: String { "\(unitLabel)/100km" }

    public var isElectric: Bool { self == .electric }
}

/// The driver's vehicle and running costs.
///
/// `consumptionPer100km` and `energyPrice` are the two numbers the driver is
/// asked for during onboarding. Everything else has a sane default so the
/// first-run flow stays short — a driver setting this up in a car park will
/// not fill in fourteen fields.
public struct VehicleProfile: Equatable, Codable, Sendable {
    public var label: String
    public var fuelType: FuelType
    /// Litres (or kWh) per 100 km. Real-world figure, not the brochure one.
    public var consumptionPer100km: Double
    /// Price per litre (or per kWh) at the driver's usual station.
    public var energyPrice: Double
    public var currency: String

    public init(
        label: String = "My car",
        fuelType: FuelType = .petrol,
        consumptionPer100km: Double = 7.0,
        energyPrice: Double = 7.5,
        currency: String = "RON"
    ) {
        self.label = label
        self.fuelType = fuelType
        self.consumptionPer100km = consumptionPer100km
        self.energyPrice = energyPrice
        self.currency = currency
    }

    /// Cost of energy alone, per kilometre.
    public var energyCostPerKm: Double { (consumptionPer100km / 100.0) * energyPrice }

    /// Marginal cost of putting one more kilometre on this car.
    ///
    /// Fuel only. Tyres, servicing and depreciation are real costs, but asking
    /// a driver to put a number on them at a petrol station is asking him to
    /// invent one — and an invented input propagates into every verdict looking
    /// exactly as authoritative as the two figures he actually knows. Two
    /// honest inputs beat three where one is a guess.
    public var totalCostPerKm: Double { energyCostPerKm }

    public var isPlausible: Bool {
        consumptionPer100km > 0.0
            && consumptionPer100km < 100.0
            && energyPrice > 0.0
    }

    /// Sensible starting point for a Romanian Bolt/Uber driver:
    /// ~7 L/100km petrol at ~7.5 RON/L.
    public static let defaultRO = VehicleProfile()
}

/// The bar an offer has to clear. Drives the green / amber / red verdict.
///
/// Defaults are deliberately modest so a new user is not drowned in red on
/// day one; the settings screen nudges them to raise it once they have a
/// week of history to look at.
public struct DriverThresholds: Equatable, Codable, Sendable {
    /// Minimum acceptable NET earnings per hour, after all costs.
    public var minNetPerHour: Double
    /// Minimum acceptable NET earnings per kilometre driven.
    public var minNetPerKm: Double
    /// Maximum tolerable pickup-km ÷ trip-km. Above roughly 1.0 you are
    /// driving further to collect than you are paid to carry. This is the
    /// number that catches the deceptively-fine-looking bad offer.
    public var maxDeadheadRatio: Double
    /// Offers below this absolute net are rejected regardless of rates.
    public var minNetTotal: Double

    public init(
        minNetPerHour: Double = 40.0,
        minNetPerKm: Double = 1.5,
        maxDeadheadRatio: Double = 0.8,
        minNetTotal: Double = 0.0
    ) {
        self.minNetPerHour = minNetPerHour
        self.minNetPerKm = minNetPerKm
        self.maxDeadheadRatio = maxDeadheadRatio
        self.minNetTotal = minNetTotal
    }
}

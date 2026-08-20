import Foundation

/// A ride-hailing driver app we can read offers from.
///
/// `packageName` is meaningless as an iOS identifier — there is no way to ask
/// what app is in the foreground, let alone read it. It is kept because it is
/// the routing key `OfferParserRegistry` uses on both platforms, and because
/// fixtures recorded on Android must replay byte-identically here. On iOS the
/// value is synthesised from whichever platform the screenshot looks like.
///
/// Raw values are stable persistence keys: they end up in `UserDefaults` and
/// in the history JSON, so they must never be renamed even if the case names
/// change.
public enum Platform: String, CaseIterable, Codable, Sendable {
    case bolt = "BOLT"
    case uber = "UBER"
    case unknown = "UNKNOWN"

    public var packageName: String {
        switch self {
        case .bolt: return "ee.mtakso.driver"
        case .uber: return "com.ubercab.driver"
        case .unknown: return ""
        }
    }

    public var displayName: String {
        switch self {
        case .bolt: return "Bolt"
        case .uber: return "Uber"
        case .unknown: return "Unknown"
        }
    }

    /// Zero for every platform, and that is not an oversight.
    ///
    /// Both Romanian driver apps print the driver's own take on the card. Bolt
    /// spells it out — `11,62 lei (NET, taxe incluse)` — and Uber labels the
    /// figure `Câștig net (fără comisionul Uber)`. There is nothing left to
    /// subtract. An earlier version defaulted Bolt to a 20% take rate, which
    /// made every Bolt offer read a fifth worse than reality: nothing crashed,
    /// no test failed, the numbers were simply and quietly wrong, and a
    /// pessimistic verdict talks a driver out of rides that were fine.
    ///
    /// The field survives because commission is real in other markets and the
    /// calculator still models it. It just has no default to apply here.
    public var defaultCommissionRate: Double { 0.0 }

    /// Whether the fare shown on the offer card is ALREADY net of commission.
    /// True everywhere for the same reason as above — verified against
    /// screenshots of live offers, not against documentation.
    public var fareShownIsNetByDefault: Bool { true }

    public static func fromPackage(_ pkg: String?) -> Platform {
        allCases.first { !$0.packageName.isEmpty && $0.packageName == pkg } ?? .unknown
    }

    /// Packages a parser will accept. On Android this also feeds
    /// `accessibility_service_config.xml`; on iOS it is only the routing set.
    public static let watchedPackages: [String] =
        allCases.map(\.packageName).filter { !$0.isEmpty }

    /// The platforms a driver can actually pick in the UI — `unknown` is a
    /// parsing outcome, never a choice.
    public static let selectable: [Platform] = [.bolt, .uber]
}

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

    /// Default platform take rate. Varies by country, driver tier and
    /// promotion, so it is only a starting value — the driver overrides it in
    /// settings after checking a real payout statement.
    public var defaultCommissionRate: Double {
        switch self {
        case .bolt: return 0.20
        case .uber: return 0.25
        case .unknown: return 0.0
        }
    }

    /// Whether the fare shown on the offer card is ALREADY net of commission.
    /// This differs by market and is the single easiest way to be quietly
    /// wrong by 20%. Always verify against a real weekly statement.
    public var fareShownIsNetByDefault: Bool {
        switch self {
        case .bolt: return false
        case .uber: return true
        case .unknown: return true
        }
    }

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

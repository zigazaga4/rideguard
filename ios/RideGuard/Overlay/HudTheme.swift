import UIKit
import RideGuardCore

/// The HUD's palette, taken value-for-value from
/// `android/overlay/src/main/kotlin/com/rideguard/overlay/OverlayHud.kt`.
///
/// A driver who has used the Android build — or who compares notes with someone
/// who has — must see the same colour mean the same thing. If these drift, amber
/// on one phone becomes the green on the other and the whole glance-and-decide
/// premise breaks.
enum HudColors {
    static let good = hex(0x16A34A)
    static let marginal = hex(0xF59E0B)
    static let bad = hex(0xDC2626)
    static let unknown = hex(0x64748B)

    /// Near-opaque rather than translucent. The HUD sits over a bright map in
    /// daylight, and anything you can see through stops being readable at the
    /// two-second glance this is designed for.
    static let surface = hex(0x141619, alpha: 0.949)
    static let primary = hex(0xF5F7FA)
    static let secondary = hex(0x9AA4B2)

    /// The verdict crosses the process boundary as a `String` on purpose (see
    /// `LiveVerdict.verdict`). An unrecognised value therefore has to land on
    /// UNKNOWN: a version skew between the app and the broadcast extension must
    /// degrade to "could not read it", never to a confident colour.
    static func forVerdict(_ raw: String) -> UIColor {
        switch raw.uppercased() {
        case "GOOD": return good
        case "MARGINAL": return marginal
        case "BAD": return bad
        default: return unknown
        }
    }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }
}

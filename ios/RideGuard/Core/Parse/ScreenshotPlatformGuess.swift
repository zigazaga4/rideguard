import Foundation

//  Pure, framework-free half of the iOS capture story. It lives in Core so the
//  guess can be unit-tested on any machine with a Swift toolchain; the Vision
//  half that produces the text it reasons about lives outside Core, in
//  `RideGuard/Capture`, because Core must import nothing but Foundation.

/// Guesses which driver app a shared screenshot came from.
///
/// On Android the package name is authoritative. Here there is no package
/// name — an image carries no provenance — so we sniff the text. Kept pure and
/// outside the Vision guard so it is testable on any platform.
public enum ScreenshotPlatformGuess {

    private static let boltMarkers = [
        "bolt", "comandă nouă", "comanda noua", "cursă nouă", "cursa noua", "acceptă", "mtakso",
    ]
    private static let uberMarkers = [
        "uber", "uberx", "uber comfort", "trip request", "accept", "you're online",
    ]

    /// Returns the better-supported guess, or `fallback` when the text gives
    /// no signal either way.
    ///
    /// `fallback` is the platform the driver picked in settings, because a
    /// driver who works one app overwhelmingly gets offers from that app, and
    /// guessing wrong only changes the commission default — which the verdict
    /// card shows and the driver can correct in one tap.
    public static func guess(from text: String, fallback: Platform) -> Platform {
        let haystack = text.lowercased()
        let bolt = boltMarkers.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
        let uber = uberMarkers.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
        if bolt > uber { return .bolt }
        if uber > bolt { return .uber }
        return fallback
    }
}

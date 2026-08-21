import Foundation

//  Pure, framework-free half of the iOS capture story. It lives in Core so the
//  guess can be unit-tested on any machine with a Swift toolchain; the Vision
//  half that produces the text it reasons about lives outside Core, in
//  `RideGuard/Capture`, because Core must import nothing but Foundation.

/// Works out which driver app a captured frame came from, by reading it.
///
/// On Android the package name is authoritative and this problem does not
/// exist. Here there is none — a ReplayKit frame carries no provenance at all
/// — so the text has to say. This is the only platform-routing decision the
/// live pipeline makes, which is why it refuses to guess (see `strictGuess`).
///
/// ## Why the markers are what they are
///
/// Every string below was taken from a screenshot of a real Romanian offer
/// card, not guessed from the English apps. Two things that costs us:
///
/// 1. **Neither card says "Accept".** Both accept buttons read `Potrivire`.
///    An earlier version listed `"accept"` as an Uber marker, which then
///    matched Bolt's own disclaimer — *"…nu va afecta rata de **accept**are"* —
///    so a genuine Bolt card scored 1–1 and fell through to the fallback. A
///    marker that appears on the other platform's card is worse than no marker.
/// 2. **Diacritics survive OCR unreliably.** Romanian ș and ț exist at two
///    different code points each (U+0219/U+015F, U+021B/U+0163) and Vision
///    picks between them inconsistently, so `câștig` is a coin flip. Every
///    decisive marker here is therefore plain ASCII.
public enum ScreenshotPlatformGuess {

    // EVERY marker below must be written in plain ASCII, because `normalise`
    // folds the haystack's diacritics away before comparing. A marker spelled
    // "cursă lungă" would never match anything.

    /// Believed present on one platform's card and impossible on the other's.
    /// The side with more hits wins outright; an equal, non-zero score means
    /// the belief was wrong about one of these, and the answer is silence.
    private static let boltDecisive = [
        "taxe incluse",     // "11,62 lei (NET, taxe incluse)"
        "afara razei",      // "În afara razei"
        "respingerea",      // "Respingerea cursei nu va afecta rata de acceptare"
    ]
    private static let uberDecisive = [
        "comisionul",       // "Câștig net (fără comisionul Uber)"
        "uberx",
        "uber comfort",
        "cursa lunga",      // "Cursă lungă (peste 45 min.)"
    ]

    /// Weaker signals: real, but capable of appearing incidentally — a Bolt
    /// receipt open inside the Uber app, an address containing the word.
    ///
    /// `cerere mare` is here rather than above for a specific reason. It is
    /// Bolt's surge chip, and it was decisive until it turned out nobody has
    /// ever captured an Uber surge card in Romanian — so "Uber does not say
    /// this" was an assumption, not an observation. As a Bolt-decisive marker
    /// it would have routed every surged Uber offer to the Bolt parser.
    private static let boltWeak = ["bolt", "comanda noua", "cursa noua", "mtakso", "cerere mare"]
    private static let uberWeak = ["uber", "trip request", "distanta"]

    /// Decides only when the text actually says so.
    ///
    /// Used by the live broadcast path, where there is no sensible default: a
    /// frame of the home screen is not a quiet vote for either platform, and
    /// treating it as one would attach a verdict to whatever is on screen.
    public static func strictGuess(from text: String) -> Platform? {
        let haystack = normalise(text)

        // Both sides are counted before either wins. The obvious version —
        // "if any Bolt marker matches, return Bolt" — reads the same on a card
        // that mentions one platform, and silently prefers Bolt on a card that
        // trips both. That is how `cerere mare` would have sent every surged
        // Uber offer to the Bolt parser, and it would never have shown up as a
        // failure: there would just be a verdict, with the wrong name on it.
        //
        // Counting means a marker that turns out not to be exclusive costs a
        // verdict rather than corrupting one, which is the trade this whole
        // app makes everywhere else.
        let boltHits = boltDecisive.count(matchingIn: haystack)
        let uberHits = uberDecisive.count(matchingIn: haystack)
        if boltHits > uberHits { return .bolt }
        if uberHits > boltHits { return .uber }
        // Equal and non-zero: both cards claim it. Falling through to the weak
        // markers here would let "uber" appearing once outvote a genuine tie
        // between strong ones, so this stops instead.
        if boltHits > 0 { return nil }

        let bolt = boltWeak.count(matchingIn: haystack)
        let uber = uberWeak.count(matchingIn: haystack)
        if bolt > uber { return .bolt }
        if uber > bolt { return .uber }
        return nil
    }

    /// Lowercase with every Romanian diacritic folded to ASCII.
    ///
    /// Explicit rather than `folding(options: .diacriticInsensitive)` because
    /// ș and ț each exist at two code points (comma-below U+0219/U+021B and the
    /// cedilla forms U+015F/U+0163) and Vision picks between them
    /// inconsistently — the same card OCRs both ways on different runs. Listing
    /// the pairs is the only version that behaves identically every time, and
    /// it means each marker is written exactly once.
    private static func normalise(_ text: String) -> String {
        var s = text.lowercased()
        let folds = [
            ("ă", "a"), ("â", "a"), ("î", "i"),
            ("ș", "s"), ("ş", "s"),
            ("ț", "t"), ("ţ", "t"),
        ]
        for (from, to) in folds {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return s
    }
}

private extension Array where Element == String {
    /// Markers are pre-normalised at the call site, so this stays a plain
    /// substring count.
    func count(matchingIn haystack: String) -> Int {
        reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
    }
}

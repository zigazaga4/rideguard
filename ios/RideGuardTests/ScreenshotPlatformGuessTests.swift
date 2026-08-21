import XCTest
@testable import RideGuardCore

/// Which app is this? — asked of nothing but the text on the card.
///
/// On Android the window's package name answers this and the question does not
/// exist. On iOS there is no package name anywhere in the live path: ReplayKit
/// hands over pixels, Vision turns them into strings, and that is the whole of
/// what we know. So this one function decides which parser runs, and a wrong
/// answer is not a missing verdict — it is a verdict with the wrong platform's
/// rules applied to it, shown to the driver as if it were true.
///
/// The markers asserted here are transcribed from screenshots of the live
/// Romanian apps. Legs and addresses around them are filler, present only so
/// the decisive strings are surrounded by the noise they will really be in.
final class ScreenshotPlatformGuessTests: XCTestCase {

    // MARK: - The real cards

    /// Bolt, as captured. The fare and its net disclaimer really are one text
    /// node — `11,62 lei (NET, taxe incluse)` — which is where `taxe incluse`
    /// comes from.
    private let boltCard = """
    ✕  Refuză
    🚗 Bolt
    💲 Numerar
    În afara razei
    📍 Locație
    ⏱ Oră
    11,62 lei (NET, taxe incluse)
    Respingerea cursei nu va afecta rata de acceptare
    Lichi • 5.0 ★
    2,8 km · 6 min
    Strada Aurel Vlaicu 12
    3 km · 9 min
    Bulevardul Unirii 4
    Potrivire
    """

    private let uberCard = """
    👤 UberX
    ✕
    78,16 RON
    Plata în numerar
    ★ 5,00
    Câștig net (fără comisionul Uber)
    5,4 km (12 min) distanță
    Calea Victoriei 100
    29 km (48 min)
    Aeroportul Otopeni
    🔀 Cursă lungă (peste 45 min.)
    Potrivire
    """

    func testTheRealBoltCardIsRecognised() {
        XCTAssertEqual(ScreenshotPlatformGuess.strictGuess(from: boltCard), .bolt)
    }

    func testTheRealUberCardIsRecognised() {
        XCTAssertEqual(ScreenshotPlatformGuess.strictGuess(from: uberCard), .uber)
    }

    // MARK: - Regressions

    /// Neither card says "Acceptă" or "Accept" — both accept buttons read
    /// `Potrivire`. An earlier version listed "accept" as an UBER marker, which
    /// then matched the middle of Bolt's own disclaimer, "…nu va afecta rata de
    /// **accept**are". A genuine Bolt card scored one-all and fell through.
    func testBoltsAcceptanceRateDisclaimerIsNotReadAsUber() {
        let line = "Respingerea cursei nu va afecta rata de acceptare"
        XCTAssertEqual(ScreenshotPlatformGuess.strictGuess(from: line), .bolt)
    }

    /// The reason `cerere mare` is no longer Bolt-decisive.
    ///
    /// It is Bolt's surge chip, but no Uber surge card has ever been captured
    /// in Romanian, so "Uber does not say this" was an assumption. While it was
    /// decisive AND Bolt was tested first, this card — a surged Uber offer —
    /// went to the Bolt parser and produced a confident verdict labelled Bolt.
    func testASurgedUberCardIsNotStolenByBoltsSurgeChip() {
        let surged = "Cerere mare 1.8x\n" + uberCard
        XCTAssertEqual(ScreenshotPlatformGuess.strictGuess(from: surged), .uber)
    }

    /// `ă` was once missing from the fold table, so the ASCII marker
    /// "cursa lunga" could never match the text it was written for.
    func testDiacriticsFoldSoTheLongTripChipMatches() {
        XCTAssertEqual(
            ScreenshotPlatformGuess.strictGuess(from: "🔀 Cursă lungă (peste 45 min.)"),
            .uber
        )
    }

    /// Romanian ș and ț each exist at two code points and Vision picks between
    /// them inconsistently — the same card OCRs both ways on different runs.
    /// This is why the decisive marker is `comisionul`, which has no diacritics
    /// at all: it cannot be spelled two ways. The assertion is that the choice
    /// holds regardless of how the rest of the line came back.
    func testEitherEncodingOfTheNetChipStillRoutesToUber() {
        let commaBelow = "C\u{00e2}\u{0219}tig net (f\u{0103}r\u{0103} comisionul Uber)"
        let cedilla = "C\u{00e2}\u{015F}tig net (f\u{0103}r\u{0103} comisionul Uber)"
        XCTAssertNotEqual(commaBelow, cedilla, "the two spellings must really differ")
        XCTAssertEqual(ScreenshotPlatformGuess.strictGuess(from: commaBelow), .uber)
        XCTAssertEqual(ScreenshotPlatformGuess.strictGuess(from: cedilla), .uber)
    }

    // MARK: - Refusing to answer

    /// The live path sees the lock screen, the messages app and the bank app.
    /// "No idea" has to survive all of them, because the alternative is a
    /// verdict attached to somebody's account balance.
    func testAScreenThatIsNotAnOfferGetsNoAnswer() {
        let screens = [
            "",
            "   \n  \n ",
            "Sold disponibil\n4.213,55 RON\nTransfer\nPlăți",
            "Maps\nStrada Aurel Vlaicu\n12 min\nStart",
            "Mesaje\nAjung în 5 minute\nTrimite",
        ]
        for screen in screens {
            XCTAssertNil(
                ScreenshotPlatformGuess.strictGuess(from: screen),
                "should not have guessed a platform from: \(screen)"
            )
        }
    }

    /// A card that trips both sides equally is contested, and contested means
    /// silent. Before the counting change this returned `.bolt`, because Bolt
    /// was simply tested first.
    func testACardThatClaimsBothPlatformsGetsNoAnswer() {
        let contested = "11,62 lei (NET, taxe incluse)\nCâștig net (fără comisionul Uber)"
        XCTAssertNil(ScreenshotPlatformGuess.strictGuess(from: contested))
    }

    func testATieOnWeakMarkersAloneGetsNoAnswer() {
        XCTAssertNil(ScreenshotPlatformGuess.strictGuess(from: "bolt uber"))
    }

    // MARK: - Precedence

    /// Weak markers are a tie-break, not a vote that can overturn a decisive
    /// one. A screenshot of the Uber card taken while a Bolt notification was
    /// on screen must still be Uber.
    func testOneDecisiveMarkerOutranksAPileOfWeakOnesForTheOtherPlatform() {
        let noisy = "Bolt\nBolt\nComandă nouă\nCursă nouă\nCâștig net (fără comisionul Uber)"
        XCTAssertEqual(ScreenshotPlatformGuess.strictGuess(from: noisy), .uber)
    }

    func testWeakMarkersDecideWhenNothingDecisiveIsThere() {
        XCTAssertEqual(ScreenshotPlatformGuess.strictGuess(from: "🚗 Bolt\n17,50 lei"), .bolt)
        XCTAssertEqual(ScreenshotPlatformGuess.strictGuess(from: "UberX"), .uber)
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(ScreenshotPlatformGuess.strictGuess(from: "TAXE INCLUSE"), .bolt)
        XCTAssertEqual(ScreenshotPlatformGuess.strictGuess(from: "CURSĂ LUNGĂ"), .uber)
    }

    // MARK: - The fallback variant

    /// The share extension has a sensible default — the driver handed it one
    /// image on purpose — and the live path does not. That is the only reason
    /// both functions exist, and the fallback must never override a real read.
    func testTheFallbackAppliesOnlyWhenThereIsNoIdea() {
        XCTAssertEqual(ScreenshotPlatformGuess.guess(from: "", fallback: .uber), .uber)
        XCTAssertEqual(ScreenshotPlatformGuess.guess(from: boltCard, fallback: .uber), .bolt)
        XCTAssertEqual(ScreenshotPlatformGuess.guess(from: uberCard, fallback: .bolt), .uber)
    }
}

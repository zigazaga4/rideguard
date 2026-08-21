import XCTest
@testable import RideGuardCore

/// The verdict in words.
///
/// Colour used to be the whole signal on the HUD, and the two surfaces that did
/// spell it out — the verdict card and the Live Activity — each kept their own
/// private copy of the strings. That is how the app ended up able to say
/// different things about the same ride on two screens at once.
///
/// These strings are now defined once, on `Verdict`, and this suite is what
/// stops them drifting back apart or quietly turning into something that
/// overclaims.
final class VerdictLabelTests: XCTestCase {

    func testEveryVerdictHasBothStrings() {
        for verdict in Verdict.allCases {
            XCTAssertFalse(
                verdict.statusLabel.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(verdict) has no label, so a surface showing it would render a blank"
            )
            XCTAssertFalse(
                verdict.statusDetail.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(verdict) has no detail line"
            )
        }
    }

    func testTheLabelsAreTheOnesTheDriverWasPromised() {
        XCTAssertEqual(Verdict.good.statusLabel, "Profitable")
        XCTAssertEqual(Verdict.marginal.statusLabel, "Semi-profitable")
        XCTAssertEqual(Verdict.bad.statusLabel, "Not profitable")
    }

    /// The important one. UNKNOWN means the card could not be read, which is
    /// not a middle verdict — and a driver skimming for the word "profitable"
    /// must not find it on an offer the app never actually managed to judge.
    func testUnknownNeverClaimsAnythingAboutProfit() {
        XCTAssertFalse(Verdict.unknown.statusLabel.lowercased().contains("profit"))
        XCTAssertFalse(Verdict.unknown.statusDetail.lowercased().contains("profit"))
    }

    func testNoTwoVerdictsShareALabel() {
        let labels = Verdict.allCases.map(\.statusLabel)
        XCTAssertEqual(
            Set(labels).count, labels.count,
            "two verdicts reading the same makes them indistinguishable on the HUD"
        )
    }

    /// The HUD gets the verdict as a raw string across a process boundary, and
    /// decodes it with `Verdict(rawValue:)`. Anything it cannot decode has to
    /// land on `unknown` rather than on a confident-looking word.
    func testTheRawStringsRoundTrip() {
        for verdict in Verdict.allCases {
            XCTAssertEqual(Verdict(rawValue: verdict.rawValue), verdict)
        }
        XCTAssertNil(Verdict(rawValue: "PROFITABLE"))
        XCTAssertNil(Verdict(rawValue: ""))
    }
}

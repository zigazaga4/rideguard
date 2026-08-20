import XCTest
@testable import RideGuardCore

/// These are not academic. Romanian Bolt renders `17,50 lei` and `2,4 km`;
/// a naive `Double(_:)` returns nil on the first and a naive comma-strip turns
/// `1.234` into 1.234 when the driver meant 1234. Every one of these cases has
/// a real screen behind it, and every one of them is also asserted in the
/// Kotlin `NumberParsingTest` — if the two files ever disagree, one of the two
/// apps is showing a driver the wrong number.
final class NumberParsingTests: XCTestCase {

    private func p(_ s: String?) -> Double? { NumberParsing.parseDecimal(s) }

    func testRomanianCommaDecimals() throws {
        XCTAssertEqual(try XCTUnwrap(p("17,50")), 17.50, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(p("2,4")), 2.4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(p("0,5")), 0.5, accuracy: 1e-9)
    }

    func testAngloDotDecimals() throws {
        XCTAssertEqual(try XCTUnwrap(p("17.50")), 17.50, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(p("14.2")), 14.2, accuracy: 1e-9)
    }

    func testLoneSeparatorWithThreeDigitsIsGrouping() throws {
        XCTAssertEqual(try XCTUnwrap(p("1.234")), 1234.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(p("1,234")), 1234.0, accuracy: 1e-9)
    }

    func testBothSeparatorsTheLaterOneIsTheDecimalPoint() throws {
        XCTAssertEqual(try XCTUnwrap(p("1.234,56")), 1234.56, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(p("1,234.56")), 1234.56, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(p("1.234.567,89")), 1234567.89, accuracy: 1e-9)
    }

    func testRepeatedSeparatorIsAlwaysGrouping() throws {
        XCTAssertEqual(try XCTUnwrap(p("1.234.567")), 1234567.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(p("1,234,567")), 1234567.0, accuracy: 1e-9)
    }

    func testPullsTheNumberOutOfRealCurrencyStrings() throws {
        XCTAssertEqual(try XCTUnwrap(p("17,50 lei")), 17.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(p("€14.20")), 14.2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(p("RON 32,50")), 32.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(p("  8,4 km  ")), 8.4, accuracy: 1e-9)
    }

    func testHandlesThinAndNonBreakingSpacesUsedAsGrouping() throws {
        XCTAssertEqual(try XCTUnwrap(p("1 234,5")), 1234.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(p("1\u{00a0}234,5")), 1234.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(p("1\u{202f}234,5")), 1234.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(p("1\u{2009}234,5")), 1234.5, accuracy: 1e-9)
    }

    func testNegativesSurvive() throws {
        XCTAssertEqual(try XCTUnwrap(p("-12,50")), -12.5, accuracy: 1e-9)
    }

    func testNoNumberMeansNilNotZero() {
        XCTAssertNil(p(""))
        XCTAssertNil(p("   "))
        XCTAssertNil(p("Accept"))
        XCTAssertNil(p(nil))
    }

    func testFormattingIsTerseEnoughForASmallCard() {
        XCTAssertEqual(NumberParsing.formatMoney(17.50, currency: "RON"), "17.5 RON")
        XCTAssertEqual(NumberParsing.formatMoney(18.0, currency: "RON"), "18 RON")
        XCTAssertEqual(NumberParsing.formatRate(2.3456), "2.35")
        XCTAssertEqual(NumberParsing.formatRate(41.6, decimals: 0), "42")
    }

    /// Swift-only guard. `String(format:)` with `Locale.current` would render
    /// "17,50" on a Romanian phone, and the trailing-zero trim would then eat
    /// the wrong characters. The Kotlin pins `Locale.US` for the same reason.
    func testFormattingIgnoresTheDeviceLocale() {
        XCTAssertEqual(NumberParsing.formatMoney(1234.5, currency: "RON"), "1234.5 RON")
        XCTAssertTrue(NumberParsing.formatRate(0.5).contains("."))
    }

    /// Java's `Math.round` is half-UP, Swift's `rounded()` is half-away-from-
    /// zero. They only disagree on negatives — which is exactly where a
    /// loss-making offer lives, so it is worth an assertion.
    func testRoundingMatchesTheJavaHalfUpRule() {
        XCTAssertEqual(NumberParsing.roundTo(2.5, decimals: 0), 3.0, accuracy: 1e-9)
        XCTAssertEqual(NumberParsing.roundTo(-2.5, decimals: 0), -2.0, accuracy: 1e-9)
        XCTAssertEqual(NumberParsing.roundTo(1.005, decimals: 2), 1.0, accuracy: 1e-9)
    }
}

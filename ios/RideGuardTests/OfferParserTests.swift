import XCTest
@testable import RideGuardCore

/// Synthetic fixtures standing in for real recorded ones — the same cards the
/// Kotlin `OfferParserTest` asserts against, block for block and height for
/// height, so a divergence in the port shows up here immediately.
///
/// Replace these with genuine captures the moment a shift's worth of shared
/// screenshots exists: `ScreenshotOfferReader` produces exactly this
/// `[TextBlock]` shape, so real fixtures drop straight in and these become the
/// regression suite.
final class OfferParserTests: XCTestCase {

    /// Builds a block stack laid out top-to-bottom, like a real offer card.
    private func card(_ pkg: String, _ rows: [(String, Int)]) -> ScreenSnapshot {
        var y = 100
        var blocks: [TextBlock] = []
        for (text, height) in rows {
            blocks.append(TextBlock(text: text, bounds: Bounds(left: 40, top: y, right: 640, bottom: y + height)))
            y += height + 12
        }
        return ScreenSnapshot(packageName: pkg, blocks: blocks, capturedAtMs: 1_700_000_000_000)
    }

    private func boltCard() -> ScreenSnapshot {
        card(Platform.bolt.packageName, [
            ("Comandă nouă", 40),
            ("Comfort", 34),
            ("32,50 lei", 96),          // headline fare, biggest type
            ("4,85 ★", 30),
            ("2,4 km · 5 min", 36),     // pickup leg
            ("Strada Victoriei 12", 32),
            ("8,1 km · 18 min", 36),    // paid leg
            ("Acceptă", 56),
        ])
    }

    private func uberCard() -> ScreenSnapshot {
        card(Platform.uber.packageName, [
            ("UberX", 34),
            ("€14.20", 96),
            ("4.85", 30),
            ("5 min (2.4 km) away", 36),
            ("18 min (8.1 km) trip", 36),
            ("Accept", 56),
        ])
    }

    func testBoltCardParsesWithRomanianCommaDecimals() throws {
        let offer = try XCTUnwrap(BoltOfferParser().parse(boltCard(), fareIsNet: false))

        XCTAssertEqual(offer.platform, .bolt)
        XCTAssertEqual(offer.fare, 32.50, accuracy: 1e-9)
        XCTAssertEqual(offer.currency, "RON")
        XCTAssertEqual(try XCTUnwrap(offer.pickupKm), 2.4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(offer.pickupMin), 5.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(offer.tripKm), 8.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(offer.tripMin), 18.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(offer.totalKm), 10.5, accuracy: 1e-9)
        XCTAssertEqual(offer.productName, "Comfort")
        XCTAssertEqual(try XCTUnwrap(offer.passengerRating), 4.85, accuracy: 1e-9)
        XCTAssertTrue(offer.parseConfidence > 0.9)
    }

    func testUberCardParsesWithDotDecimalsAndParenthesisedLegs() throws {
        let offer = try XCTUnwrap(UberOfferParser().parse(uberCard(), fareIsNet: true))

        XCTAssertEqual(offer.fare, 14.20, accuracy: 1e-9)
        XCTAssertEqual(offer.currency, "EUR")
        XCTAssertEqual(try XCTUnwrap(offer.pickupKm), 2.4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(offer.tripKm), 8.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(offer.pickupMin), 5.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(offer.tripMin), 18.0, accuracy: 1e-9)
        XCTAssertEqual(offer.productName, "UberX")
    }

    func testTheHeadlineFareWinsOverSmallerMoneyOnTheCard() throws {
        let snap = card(Platform.bolt.packageName, [
            ("Cursă nouă", 40),
            ("45,00 lei", 96),       // the fare
            ("bonus 5,00 lei", 28),  // small print
            ("2,0 km · 4 min", 36),
            ("9,0 km · 20 min", 36),
            ("Acceptă", 56),
        ])
        let offer = try XCTUnwrap(BoltOfferParser().parse(snap, fareIsNet: false))
        XCTAssertEqual(offer.fare, 45.00, accuracy: 1e-9)
    }

    func testASingleDistanceLeavesPickupUnknownInsteadOfAssumingZero() throws {
        // Assuming a zero-km pickup would flatter the offer exactly when the
        // driver most needs the truth. We drop confidence instead.
        let snap = card(Platform.bolt.packageName, [
            ("Comandă nouă", 40),
            ("20,00 lei", 96),
            ("6,0 km · 14 min", 36),
            ("Acceptă", 56),
        ])
        let offer = try XCTUnwrap(BoltOfferParser().parse(snap, fareIsNet: false))
        XCTAssertNil(offer.pickupKm)
        XCTAssertEqual(try XCTUnwrap(offer.tripKm), 6.0, accuracy: 1e-9)
        XCTAssertTrue(offer.parseConfidence < 0.75)
    }

    func testNonOfferScreensAreRejectedByTheGate() {
        let home = card(Platform.bolt.packageName, [
            ("Online", 40),
            ("Câștiguri astăzi", 34),
            ("245,00 lei", 60),
        ])
        XCTAssertFalse(BoltOfferParser().canParse(home))
    }

    func testRegistryRoutesByPackageName() throws {
        let registry = OfferParserRegistry()

        let bolt = try XCTUnwrap(registry.parse(boltCard()) { _ in false })
        XCTAssertEqual(bolt.platform, .bolt)

        let uber = try XCTUnwrap(registry.parse(uberCard()) { _ in true })
        XCTAssertEqual(uber.platform, .uber)

        let stranger = card("com.example.other", [("10,00 lei", 60), ("5,0 km", 30), ("accept", 40)])
        XCTAssertNil(registry.parse(stranger) { _ in false })
    }

    func testMetresDoNotGetMistakenForMinutes() throws {
        let snap = card(Platform.bolt.packageName, [
            ("Comandă nouă", 40),
            ("12,00 lei", 96),
            ("800 m · 3 min", 36),
            ("4,0 km · 9 min", 36),
            ("Acceptă", 56),
        ])
        let offer = try XCTUnwrap(BoltOfferParser().parse(snap, fareIsNet: false))
        XCTAssertEqual(try XCTUnwrap(offer.pickupKm), 0.8, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(offer.pickupMin), 3.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(offer.tripKm), 4.0, accuracy: 1e-9)
    }

    // MARK: - iOS-specific

    /// Reading order is what tells the deadhead leg from the paid leg, and on
    /// iOS the blocks arrive from Vision in whatever order the recogniser
    /// finished them in — not top-to-bottom. If the sort in `ScreenSnapshot`
    /// ever stops being stable, or stops sorting at all, the two legs swap and
    /// the verdict silently inverts.
    func testLegsAreAssignedFromGeometryNotFromArrayOrder() throws {
        let shuffled = ScreenSnapshot(
            packageName: Platform.bolt.packageName,
            blocks: [
                TextBlock(text: "8,1 km · 18 min", bounds: Bounds(left: 40, top: 400, right: 640, bottom: 436)),
                TextBlock(text: "Acceptă", bounds: Bounds(left: 40, top: 500, right: 640, bottom: 556)),
                TextBlock(text: "32,50 lei", bounds: Bounds(left: 40, top: 180, right: 640, bottom: 276)),
                TextBlock(text: "2,4 km · 5 min", bounds: Bounds(left: 40, top: 300, right: 640, bottom: 336)),
            ],
            capturedAtMs: 0
        )
        let offer = try XCTUnwrap(BoltOfferParser().parse(shuffled, fareIsNet: false))
        XCTAssertEqual(try XCTUnwrap(offer.pickupKm), 2.4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(offer.tripKm), 8.1, accuracy: 1e-9)
    }

    /// A shared screenshot carries no package name, so the platform has to be
    /// sniffed out of the recognised text.
    func testPlatformIsGuessedFromScreenshotText() {
        XCTAssertEqual(
            ScreenshotPlatformGuess.guess(from: "Comandă nouă\n32,50 lei\nAcceptă", fallback: .uber),
            .bolt
        )
        XCTAssertEqual(
            ScreenshotPlatformGuess.guess(from: "UberX\n€14.20\nAccept trip request", fallback: .bolt),
            .uber
        )
        // No signal at all: keep the driver's configured platform rather than
        // inventing one.
        XCTAssertEqual(
            ScreenshotPlatformGuess.guess(from: "17,50\n4,2 km", fallback: .bolt),
            .bolt
        )
    }

    /// The keyword gate is right for Android, where the service sees every
    /// screen. On iOS the driver deliberately shared this image, so a cropped
    /// screenshot missing the "Acceptă" button must still be parsed.
    func testScreenshotPathParsesACardWithNoAcceptButton() throws {
        let cropped = card(Platform.bolt.packageName, [
            ("32,50 lei", 96),
            ("2,4 km · 5 min", 36),
            ("8,1 km · 18 min", 36),
        ])
        let registry = OfferParserRegistry()

        XCTAssertNil(registry.parse(cropped) { _ in false }, "the Android gate rejects it")

        let offer = try XCTUnwrap(registry.parse(cropped, requireOfferKeywords: false) { _ in false })
        XCTAssertEqual(offer.fare, 32.50, accuracy: 1e-9)
    }
}

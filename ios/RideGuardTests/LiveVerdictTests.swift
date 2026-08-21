import XCTest
@testable import RideGuardCore

/// The payload that crosses the process boundary.
///
/// The broadcast extension and the app are separate processes that iOS gives us
/// no way to merge, and they are separately updatable: a driver can end up with
/// a new app bundle whose extension has not been relaunched, or the reverse.
/// So the two ends are not guaranteed to be the same build, and every
/// assertion here is about surviving that.
final class LiveVerdictTests: XCTestCase {

    private let sample = LiveVerdict(
        sequence: 42,
        visible: true,
        earningsPerKm: 4.0,
        netPerKm: 3.47,
        verdict: "GOOD",
        currency: "RON",
        totalKm: 5.8,
        netPerHour: 104.25,
        deadheadRatio: 0.93,
        platform: "bolt",
        capturedAtMs: 1_787_325_709_507
    )

    private func roundTrip(_ verdict: LiveVerdict) throws -> LiveVerdict {
        let data = try JSONEncoder().encode(verdict)
        return try JSONDecoder().decode(LiveVerdict.self, from: data)
    }

    func testEveryFieldSurvivesARoundTrip() throws {
        XCTAssertEqual(try roundTrip(sample), sample)
    }

    func testAbsentOptionalsComeBackAbsentRatherThanZero() throws {
        // A missing leg is the difference between "we could not read the
        // pickup" and "the pickup was free". Zero would flatter the offer.
        let partial = LiveVerdict(
            sequence: 1, visible: true,
            earningsPerKm: 2.0, netPerKm: 1.5,
            verdict: "MARGINAL", currency: "RON", totalKm: 4.0,
            netPerHour: nil, deadheadRatio: nil,
            platform: "uber", capturedAtMs: 1
        )
        let decoded = try roundTrip(partial)
        XCTAssertNil(decoded.netPerHour)
        XCTAssertNil(decoded.deadheadRatio)
        XCTAssertEqual(decoded, partial)
    }

    func testHiddenCarriesNoNumbersToMisread() {
        let hidden = LiveVerdict.hidden(sequence: 7)
        XCTAssertEqual(hidden.sequence, 7)
        XCTAssertFalse(hidden.visible)
        XCTAssertEqual(hidden.earningsPerKm, 0)
        XCTAssertEqual(hidden.netPerKm, 0)
        XCTAssertEqual(hidden.totalKm, 0)
        XCTAssertNil(hidden.netPerHour)
        XCTAssertNil(hidden.deadheadRatio)
        XCTAssertEqual(hidden.capturedAtMs, 0)
    }

    /// The overlay drops anything not newer, so `hidden` must be able to win.
    func testHiddenIsOrderedLikeAnyOtherVerdict() {
        XCTAssertGreaterThan(LiveVerdict.hidden(sequence: 43).sequence, sample.sequence)
    }

    // MARK: - Version skew

    /// A NEWER extension writing a field this build has never heard of must not
    /// take the HUD down. Synthesised `Codable` ignores unknown keys, and this
    /// pins that, because the day it stops being true is the day an update
    /// ships a dead HUD and nothing logs why.
    func testAFieldFromAFutureBuildIsIgnored() throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any]
        )
        object["surgeMultiplier"] = 1.8
        object["somethingNobodyHasWrittenYet"] = ["nested": true]

        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(LiveVerdict.self, from: data), sample)
    }

    /// `verdict` is a String and not the `Verdict` enum precisely so this
    /// works. An enum would fail to decode the WHOLE payload over one unknown
    /// case, turning a new verdict name into no HUD at all.
    func testAnUnrecognisedVerdictNameDecodesInsteadOfFailing() throws {
        let exotic = LiveVerdict(
            sequence: 2, visible: true,
            earningsPerKm: 9, netPerKm: 8,
            verdict: "SPECTACULAR", currency: "RON", totalKm: 3,
            netPerHour: nil, deadheadRatio: nil,
            platform: "bolt", capturedAtMs: 5
        )
        XCTAssertEqual(try roundTrip(exotic).verdict, "SPECTACULAR")
    }

    /// The other direction, documented rather than defended: an OLDER extension
    /// that omits a required key produces no verdict, not a half-filled one.
    /// `read()` returns nil and the HUD shows its waiting state — which is the
    /// right failure, but it is a failure, so adding a non-optional field to
    /// this struct is a breaking change to a shipped app.
    func testAMissingRequiredFieldFailsToDecodeRatherThanDefaulting() throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any]
        )
        object.removeValue(forKey: "netPerKm")

        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(LiveVerdict.self, from: data))
    }

    // MARK: - The channel

    /// This string appears in three `.entitlements` files and in
    /// `Persistence.appGroupIdentifier`. If they ever disagree, the extension
    /// writes into a container the app cannot read and the HUD simply never
    /// updates, with nothing logged anywhere. Changing it must be deliberate.
    func testTheAppGroupIdentifierIsTheOneTheEntitlementsGrant() {
        XCTAssertEqual(LiveVerdictChannel.appGroupIdentifier, "group.com.priemschi.rideguard.shared")
    }

    /// Darwin notification names are a device-wide namespace shared with every
    /// other process, so this stays reverse-DNS.
    func testTheNotificationNameIsNamespaced() {
        XCTAssertTrue(LiveVerdictChannel.notificationName.hasPrefix("com.rideguard."))
    }
}

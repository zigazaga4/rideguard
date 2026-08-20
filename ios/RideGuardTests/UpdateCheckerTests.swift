import XCTest
@testable import RideGuardCore

/// The updater's whole job is to be right about one integer and harmless about
/// everything else. These tests pin both halves.
///
/// The Android updater reads the same file and must reach the same conclusions
/// from it; if these rules and the Kotlin ones ever disagree, one of the two
/// phones is being told the wrong thing about which build it should run.
final class UpdateCheckerTests: XCTestCase {

    private let installed = AppVersion(version: "1.1.0", build: 2)

    private func manifest(_ json: String) throws -> UpdateManifest {
        try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
    }

    private func status(_ json: String, current: AppVersion? = nil, os: String = "17.0") throws -> UpdateStatus {
        UpdateComparison.evaluate(
            manifest: try manifest(json),
            current: current ?? installed,
            osVersion: os
        )
    }

    /// The full shape from the spec, as it will actually be published.
    private let fullManifest = """
    {
      "schemaVersion": 1,
      "publishedAt": "2026-08-20T17:00:00Z",
      "notes": "Short human-readable changelog, may be multi-line.",
      "mandatory": false,
      "android": {
        "versionCode": 3,
        "versionName": "1.2.0",
        "url": "https://github.com/zigazaga4/rideguard/releases/download/v1.2.0/rideguard-sideload.apk",
        "sha256": "abc123",
        "sizeBytes": 61973326,
        "minSdk": 26
      },
      "ios": {
        "version": "1.2.0",
        "build": 3,
        "manifestUrl": "https://github.com/zigazaga4/rideguard/releases/download/v1.2.0/manifest.plist",
        "minIosVersion": "16.0"
      }
    }
    """

    // MARK: - The integer decides

    func testANewerBuildIsOffered() throws {
        let status = try status(fullManifest)
        let release = try XCTUnwrap(status.release)
        XCTAssertEqual(release.build, 3)
        XCTAssertEqual(release.version, "1.2.0")
    }

    func testTheSameBuildIsNotOffered() throws {
        XCTAssertEqual(try status(fullManifest, current: AppVersion(version: "1.2.0", build: 3)), .upToDate)
    }

    func testAnOlderPublishedBuildIsNotOffered() throws {
        // A rolled-back release must not walk a driver backwards.
        XCTAssertEqual(try status(fullManifest, current: AppVersion(version: "2.0.0", build: 9)), .upToDate)
    }

    /// The display string is decoration. "1.10.0" sorts BEFORE "1.9.0" as text,
    /// which is precisely the bug comparing strings would introduce.
    func testTheDisplayVersionIsIgnoredEvenWhenItLooksOlder() throws {
        let json = """
        {"schemaVersion":1,"ios":{"version":"0.9.0-beta","build":99,"manifestUrl":"https://example.com/m.plist"}}
        """
        XCTAssertEqual(try XCTUnwrap(try status(json).release).build, 99)

        let stringSortTrap = """
        {"schemaVersion":1,"ios":{"version":"1.10.0","build":3,"manifestUrl":"https://example.com/m.plist"}}
        """
        XCTAssertNotNil(try status(stringSortTrap, current: AppVersion(version: "1.9.0", build: 2)).release)
    }

    // MARK: - Missing and malformed

    func testAnAndroidOnlyReleaseIsNotAnError() throws {
        let json = """
        {"schemaVersion":1,"android":{"versionCode":5,"versionName":"1.3.0","url":"https://example.com/a.apk"}}
        """
        XCTAssertEqual(try status(json), .noReleaseForThisPlatform)
    }

    func testAnEmptyReleaseIsNotAnError() throws {
        XCTAssertEqual(try status(#"{"schemaVersion":1}"#), .noReleaseForThisPlatform)
    }

    /// A broken Android block must not cost an iPhone its update. The two
    /// platforms ship independently and a typo in one half of the file is not
    /// a reason to strand the other.
    func testAMalformedAndroidBlockDoesNotHideTheIosRelease() throws {
        let json = """
        {"schemaVersion":1,
         "android":{"versionName":"1.3.0"},
         "ios":{"version":"1.3.0","build":7,"manifestUrl":"https://example.com/m.plist"}}
        """
        let parsed = try manifest(json)
        XCTAssertNil(parsed.android)
        XCTAssertEqual(try XCTUnwrap(try status(json).release).build, 7)
    }

    /// `build` and `manifestUrl` are the two fields without which the block is
    /// not actionable, so their absence reads as "no iOS build", never a crash.
    func testAnIosBlockWithoutABuildNumberIsTreatedAsAbsent() throws {
        let json = """
        {"schemaVersion":1,"ios":{"version":"1.3.0","manifestUrl":"https://example.com/m.plist"}}
        """
        XCTAssertEqual(try status(json), .noReleaseForThisPlatform)
    }

    func testMissingOptionalFieldsFallBackInsteadOfThrowing() throws {
        let parsed = try manifest(#"{"schemaVersion":1,"ios":{"build":4,"manifestUrl":"https://example.com/m.plist"}}"#)
        XCTAssertEqual(parsed.notes, "")
        XCTAssertFalse(parsed.mandatory)
        XCTAssertNil(parsed.publishedAt)
        XCTAssertEqual(parsed.ios?.version, "")
        XCTAssertNil(parsed.ios?.minIosVersion)
    }

    func testMandatoryAndNotesAreReadWhenPresent() throws {
        let parsed = try manifest(fullManifest)
        XCTAssertFalse(parsed.mandatory)
        XCTAssertTrue(parsed.notes.hasPrefix("Short human-readable"))
        XCTAssertNotNil(parsed.publishedDate)
        XCTAssertEqual(parsed.android?.versionCode, 3)
        XCTAssertEqual(parsed.android?.sizeBytes, 61_973_326)
    }

    func testGarbageIsNotFatal() async {
        let result = await UpdateChecker(
            currentVersion: installed,
            osVersion: "17.0",
            fetch: { _ in Data("<!DOCTYPE html><html>404</html>".utf8) }
        ).check()

        guard case .couldNotCheck = result.status else {
            return XCTFail("malformed JSON must be survivable, got \(result.status)")
        }
        XCTAssertNil(result.manifest)
        XCTAssertEqual(result.current, installed)
    }

    func testNoNetworkIsNotFatal() async {
        struct Offline: Error {}
        let result = await UpdateChecker(
            currentVersion: installed,
            osVersion: "17.0",
            fetch: { _ in throw Offline() }
        ).check()

        guard case .couldNotCheck = result.status else {
            return XCTFail("an unreachable GitHub must be survivable, got \(result.status)")
        }
    }

    func testAWholeCheckOverAStubbedFetchReachesTheRightVerdict() async throws {
        let json = fullManifest
        let result = await UpdateChecker(
            currentVersion: installed,
            osVersion: "17.0",
            fetch: { _ in Data(json.utf8) }
        ).check()

        XCTAssertEqual(try XCTUnwrap(result.status.release).build, 3)
        XCTAssertEqual(result.manifest?.schemaVersion, 1)
    }

    // MARK: - Schema

    func testAHigherSchemaVersionStopsRatherThanGuesses() throws {
        let json = """
        {"schemaVersion":2,"ios":{"version":"9.9.9","build":999,"manifestUrl":"https://example.com/m.plist"}}
        """
        XCTAssertEqual(try status(json), .unsupportedSchema(found: 2, supported: 1))
    }

    func testAnUnknownLowerSchemaVersionAlsoStops() throws {
        let json = """
        {"schemaVersion":0,"ios":{"version":"1.3.0","build":9,"manifestUrl":"https://example.com/m.plist"}}
        """
        XCTAssertEqual(try status(json), .unsupportedSchema(found: 0, supported: 1))
    }

    func testAManifestWithoutASchemaVersionIsUnreadableRatherThanAssumedToBeV1() {
        XCTAssertThrowsError(try manifest(#"{"ios":{"build":9,"manifestUrl":"https://example.com/m.plist"}}"#))
    }

    // MARK: - Device floor

    func testABuildThatNeedsANewerIOSIsNotOffered() throws {
        let json = """
        {"schemaVersion":1,"ios":{"version":"2.0.0","build":10,"manifestUrl":"https://example.com/m.plist","minIosVersion":"18.0"}}
        """
        XCTAssertEqual(
            try status(json, os: "16.4.1"),
            .requiresNewerOS(required: "18.0", current: "16.4.1")
        )
    }

    func testTheDeviceFloorIsInclusive() throws {
        let json = """
        {"schemaVersion":1,"ios":{"version":"2.0.0","build":10,"manifestUrl":"https://example.com/m.plist","minIosVersion":"16.0"}}
        """
        XCTAssertNotNil(try status(json, os: "16.0").release)
        XCTAssertNotNil(try status(json, os: "16.0.3").release)
    }

    func testDottedVersionsCompareNumericallyNotAlphabetically() {
        XCTAssertEqual(UpdateComparison.compareDotted("16.10", "16.9"), .orderedDescending)
        XCTAssertEqual(UpdateComparison.compareDotted("17", "17.0.0"), .orderedSame)
        XCTAssertEqual(UpdateComparison.compareDotted("16.4.1", "16.5"), .orderedAscending)
    }

    // MARK: - The install URL

    func testTheInstallURLWrapsTheManifestForItmsServices() throws {
        let release = try XCTUnwrap(try manifest(fullManifest).ios)
        let url = try XCTUnwrap(release.otaInstallURL)

        XCTAssertEqual(url.scheme, "itms-services")
        let absolute = url.absoluteString
        XCTAssertTrue(absolute.hasPrefix("itms-services://?action=download-manifest&url="))
        // The wrapped URL must be encoded whole. An unescaped "://" or "&"
        // truncates the parameter and iOS reports a meaningless failure.
        XCTAssertFalse(absolute.dropFirst("itms-services://?action=download-manifest&url=".count).contains("/"))
        XCTAssertTrue(absolute.contains("https%3A%2F%2Fgithub.com"))
    }

    func testAPlainHTTPManifestIsRefusedRatherThanOffered() {
        // iOS silently refuses a non-HTTPS OTA manifest, so a button here would
        // do nothing at all when tapped.
        XCTAssertNil(UpdateManifest.otaInstallURL(forManifestAt: "http://example.com/manifest.plist"))
        XCTAssertNil(UpdateManifest.otaInstallURL(forManifestAt: ""))
        XCTAssertNil(UpdateManifest.otaInstallURL(forManifestAt: "not a url at all"))
    }

    // MARK: - Bundle reading

    /// `CFBundleVersion` must stay an integer. If a release script ever writes
    /// "1.2.0" there, the installed build reads as 0 and every published
    /// release looks newer — an app that nags forever, which is the right
    /// failure direction but still a failure.
    func testANonIntegerBundleVersionReadsAsZeroRatherThanCrashing() {
        let parsed = AppVersion.current(info: ["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "1.2.0"])
        XCTAssertEqual(parsed, AppVersion(version: "1.2.0", build: 0))
    }

    func testAnIntegerBundleVersionReadsThrough() {
        let parsed = AppVersion.current(info: ["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "3"])
        XCTAssertEqual(parsed, AppVersion(version: "1.2.0", build: 3))
    }

    func testAnEmptyBundleDoesNotCrash() {
        XCTAssertEqual(AppVersion.current(info: nil), AppVersion(version: "0", build: 0))
    }
}

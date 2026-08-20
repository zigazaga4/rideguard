import Foundation

//  The shared update manifest, published at a stable raw URL on the GitHub
//  repo and read by BOTH platforms:
//
//      https://raw.githubusercontent.com/zigazaga4/rideguard/main/updates/latest.json
//
//  Android downloads an APK from it and installs it with `PackageInstaller`.
//  iOS cannot install anything from inside an app, so it uses the `manifestUrl`
//  to hand iOS an `itms-services://` OTA install — see `docs/ios-updates.md`.
//  The file format is identical on purpose: one release process, one file to
//  get right, and a version skew between the two apps is immediately visible.

/// One release, as published to GitHub.
///
/// Decoding is hand-written rather than synthesised because every rule this
/// type has to honour is a leniency rule: a missing `mandatory`, a missing
/// platform block, or a malformed sibling block must all leave the rest of the
/// manifest usable. Synthesised `Codable` throws on the first missing key,
/// which would turn "no Android build this time" into "update check broken".
public struct UpdateManifest: Equatable, Sendable {

    /// The only schema this build understands. Anything else — higher, lower,
    /// or nonsense — means the payload may not mean what we think it means.
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    /// ISO-8601, kept as the raw string. Parsed on demand rather than through
    /// a `JSONDecoder` date strategy, so a publisher who writes a slightly odd
    /// timestamp costs us a formatted date, not the whole update check.
    public let publishedAt: String?
    public let notes: String
    public let mandatory: Bool
    public let android: AndroidRelease?
    public let ios: IOSRelease?

    public init(
        schemaVersion: Int,
        publishedAt: String? = nil,
        notes: String = "",
        mandatory: Bool = false,
        android: AndroidRelease? = nil,
        ios: IOSRelease? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.publishedAt = publishedAt
        self.notes = notes
        self.mandatory = mandatory
        self.android = android
        self.ios = ios
    }

    public var publishedDate: Date? {
        guard let publishedAt else { return nil }
        return ISO8601DateFormatter().date(from: publishedAt)
    }

    /// The Android half. iOS never acts on it — it is decoded so a malformed
    /// Android block is proven harmless rather than assumed to be.
    public struct AndroidRelease: Equatable, Sendable {
        public let versionCode: Int
        public let versionName: String
        public let url: String
        public let sha256: String?
        public let sizeBytes: Int64?
        public let minSdk: Int?

        public init(
            versionCode: Int,
            versionName: String,
            url: String,
            sha256: String? = nil,
            sizeBytes: Int64? = nil,
            minSdk: Int? = nil
        ) {
            self.versionCode = versionCode
            self.versionName = versionName
            self.url = url
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
            self.minSdk = minSdk
        }
    }

    public struct IOSRelease: Equatable, Sendable {
        /// Display string. For humans only — never compared.
        public let version: String
        /// `CFBundleVersion`. THE comparison key: an integer that only ever
        /// goes up. Comparing "1.10.0" against "1.9.0" as strings puts the
        /// newer build behind the older one, which is how an updater ends up
        /// silently never updating.
        public let build: Int
        /// HTTPS URL of the `manifest.plist` handed to `itms-services://`.
        /// Apple requires HTTPS with a valid certificate; a GitHub release
        /// asset URL qualifies.
        public let manifestUrl: String
        /// Below this, the OTA install will fail on the device. Optional, and
        /// treated as "no floor" when absent.
        public let minIosVersion: String?
        /// Not in the v1 schema. Decoded when a publisher includes it, because
        /// the install prompt gives the driver no size at all and a driver on
        /// mobile data deserves to know before tapping.
        public let sizeBytes: Int64?

        public init(
            version: String,
            build: Int,
            manifestUrl: String,
            minIosVersion: String? = nil,
            sizeBytes: Int64? = nil
        ) {
            self.version = version
            self.build = build
            self.manifestUrl = manifestUrl
            self.minIosVersion = minIosVersion
            self.sizeBytes = sizeBytes
        }

        /// The URL that makes iOS offer to install this build.
        ///
        /// Nil when the manifest URL is not HTTPS: iOS silently refuses plain
        /// HTTP here, and a button that does nothing when tapped is worse than
        /// a button that is not offered.
        public var otaInstallURL: URL? {
            UpdateManifest.otaInstallURL(forManifestAt: manifestUrl)
        }
    }

    /// `itms-services://?action=download-manifest&url=<https url>`
    ///
    /// The URL is percent-encoded against an explicitly unreserved set rather
    /// than `.urlQueryAllowed`, which leaves `&` and `=` untouched — a release
    /// asset URL carrying a query string would otherwise truncate the
    /// parameter and iOS would report a meaningless "cannot connect".
    public static func otaInstallURL(forManifestAt manifestUrl: String) -> URL? {
        let trimmed = manifestUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed), parsed.scheme?.lowercased() == "https" else { return nil }
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "itms-services://?action=download-manifest&url=\(encoded)")
    }
}

// MARK: - Decoding

private extension KeyedDecodingContainer {
    /// Absent, null, or the wrong type all read as nil.
    ///
    /// A publisher who writes `"mandatory": "false"` should cost us that one
    /// field, not the whole update check. Everything the updater does is a
    /// convenience; nothing about it is worth failing loudly over.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

extension UpdateManifest: Decodable {

    private enum Key: String, CodingKey {
        case schemaVersion, publishedAt, notes, mandatory, android, ios
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        // The one genuinely required field. Without it we cannot know whether
        // the rest of the payload means what we think it means.
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        publishedAt = c.lenient(String.self, .publishedAt)
        notes = c.lenient(String.self, .notes) ?? ""
        mandatory = c.lenient(Bool.self, .mandatory) ?? false
        // Each block is decoded leniently on its own: a broken Android block
        // must not cost an iPhone its update, and vice versa.
        android = c.lenient(AndroidRelease.self, .android)
        ios = c.lenient(IOSRelease.self, .ios)
    }
}

extension UpdateManifest.AndroidRelease: Decodable {
    private enum Key: String, CodingKey {
        case versionCode, versionName, url, sha256, sizeBytes, minSdk
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        versionCode = try c.decode(Int.self, forKey: .versionCode)
        versionName = c.lenient(String.self, .versionName) ?? ""
        url = try c.decode(String.self, forKey: .url)
        sha256 = c.lenient(String.self, .sha256)
        sizeBytes = c.lenient(Int64.self, .sizeBytes)
        minSdk = c.lenient(Int.self, .minSdk)
    }
}

extension UpdateManifest.IOSRelease: Decodable {
    private enum Key: String, CodingKey {
        case version, build, manifestUrl, minIosVersion, sizeBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        // `build` and `manifestUrl` are the two fields without which this block
        // is not actionable, so their absence makes the block absent — which
        // reads downstream as "no iOS build in this release", never an error.
        version = c.lenient(String.self, .version) ?? ""
        build = try c.decode(Int.self, forKey: .build)
        manifestUrl = try c.decode(String.self, forKey: .manifestUrl)
        minIosVersion = c.lenient(String.self, .minIosVersion)
        sizeBytes = c.lenient(Int64.self, .sizeBytes)
    }
}

// MARK: - The installed build

/// What this copy of the app is, for comparison against the manifest.
public struct AppVersion: Equatable, Sendable {
    /// `CFBundleShortVersionString` — "1.2.0". Shown, never compared.
    public let version: String
    /// `CFBundleVersion` — the monotonic integer everything is decided on.
    public let build: Int

    public init(version: String, build: Int) {
        self.version = version
        self.build = build
    }

    /// A `CFBundleVersion` that is not an integer (say "1.2.0") reads as build
    /// 0, which makes every published build look newer. That is the right
    /// failure direction — the driver is offered an update they may not need,
    /// rather than silently pinned to an old build forever — but the release
    /// script should keep `CFBundleVersion` an integer. See `ios/README.md`.
    public static func current(bundle: Bundle = .main) -> AppVersion {
        current(info: bundle.infoDictionary)
    }

    /// Split out from the `Bundle` accessor so the parsing is testable without
    /// subclassing `Bundle`, which has no public designated initialiser worth
    /// fighting.
    public static func current(info: [String: Any]?) -> AppVersion {
        let info = info ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let rawBuild = info["CFBundleVersion"] as? String ?? "0"
        return AppVersion(version: version, build: Int(rawBuild) ?? 0)
    }
}

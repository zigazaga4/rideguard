import Foundation

#if canImport(FoundationNetworking)
// Linux's Foundation splits URLSession out. Present so the domain — including
// this file — still compiles under `swift test` on a machine without Xcode.
import FoundationNetworking
#endif

/// What the update check concluded. One value the UI can switch over, with no
/// separate error channel: "could not reach GitHub" is a state of the check,
/// not an exception, and rendering it as anything scarier than a grey line
/// misrepresents how much it matters.
public enum UpdateStatus: Equatable, Sendable {
    /// Installed build is at or ahead of the published one.
    case upToDate
    case available(UpdateManifest.IOSRelease)
    /// The release shipped Android only. Not an error — releases are allowed
    /// to be one-sided, and a driver on the other platform sees nothing wrong.
    case noReleaseForThisPlatform
    /// The manifest says it is written in a schema this build does not know.
    /// Guessing at the payload is how an updater installs the wrong artefact,
    /// so it stops and says so.
    case unsupportedSchema(found: Int, supported: Int)
    /// A newer build exists but this iPhone is too old to install it. Told
    /// plainly, because the OTA prompt's own failure message says nothing
    /// useful.
    case requiresNewerOS(required: String, current: String)
    /// No network, GitHub down, DNS captive portal, or a manifest that is not
    /// JSON. Always survivable.
    case couldNotCheck(reason: String)

    public var release: UpdateManifest.IOSRelease? {
        if case .available(let release) = self { return release }
        return nil
    }

    public var isActionable: Bool { release != nil }
}

public struct UpdateCheckResult: Equatable, Sendable {
    public let status: UpdateStatus
    /// Kept even when the status is not actionable, so the UI can show the
    /// release notes of a build the driver already has.
    public let manifest: UpdateManifest?
    public let current: AppVersion
    public let checkedAt: Date

    public init(status: UpdateStatus, manifest: UpdateManifest?, current: AppVersion, checkedAt: Date = Date()) {
        self.status = status
        self.manifest = manifest
        self.current = current
        self.checkedAt = checkedAt
    }
}

/// The comparison rules, with no I/O anywhere near them.
///
/// Both platforms implement these identically; if the two ever disagree the
/// bug is here, in one small pure function that a test can pin down, rather
/// than somewhere in a networking stack.
public enum UpdateComparison {

    /// - Parameter osVersion: the running iOS version, dotted. Injected rather
    ///   than read from `ProcessInfo` so the minimum-version rule is testable.
    public static func evaluate(
        manifest: UpdateManifest,
        current: AppVersion,
        osVersion: String
    ) -> UpdateStatus {
        // Anything other than the exact schema we were written against. A
        // higher number means the publisher knows something we do not; a lower
        // one means the file predates every rule below. Both are "go and
        // update by hand", never "have a guess".
        guard manifest.schemaVersion == UpdateManifest.supportedSchemaVersion else {
            return .unsupportedSchema(
                found: manifest.schemaVersion,
                supported: UpdateManifest.supportedSchemaVersion
            )
        }

        guard let release = manifest.ios else { return .noReleaseForThisPlatform }

        // Integers only. The display string is for humans and sorts wrong:
        // "1.10.0" < "1.9.0" alphabetically, which pins an updater forever.
        guard release.build > current.build else { return .upToDate }

        if let minimum = release.minIosVersion,
           compareDotted(osVersion, minimum) == .orderedAscending {
            return .requiresNewerOS(required: minimum, current: osVersion)
        }

        return .available(release)
    }

    /// Component-wise numeric comparison of dotted versions, tolerant of
    /// differing component counts ("16" vs "16.0.0") and of junk (a
    /// non-numeric component counts as 0 rather than failing the check and
    /// blocking an update that would have worked).
    public static func compareDotted(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// Fetches the shared manifest and decides what to do about it.
///
/// Never throws and never blocks anything: a driver mid-shift with no signal
/// must get exactly the app they had before, minus one grey line of text on a
/// screen they are not looking at.
public struct UpdateChecker {

    /// The one URL both apps read. A raw githubusercontent URL rather than a
    /// release asset, because it can be updated without cutting a release and
    /// it is the same string in the Kotlin.
    public static let defaultManifestURL = URL(
        string: "https://raw.githubusercontent.com/zigazaga4/rideguard/main/updates/latest.json"
    )!

    public typealias Fetcher = @Sendable (URL) async throws -> Data

    private let manifestURL: URL
    private let fetch: Fetcher
    private let currentVersion: AppVersion
    private let osVersion: String

    public init(
        manifestURL: URL = UpdateChecker.defaultManifestURL,
        currentVersion: AppVersion = .current(),
        osVersion: String = UpdateChecker.runningOSVersion(),
        fetch: @escaping Fetcher = UpdateChecker.httpsFetch
    ) {
        self.manifestURL = manifestURL
        self.currentVersion = currentVersion
        self.osVersion = osVersion
        self.fetch = fetch
    }

    public func check() async -> UpdateCheckResult {
        let data: Data
        do {
            data = try await fetch(manifestURL)
        } catch {
            return UpdateCheckResult(
                status: .couldNotCheck(reason: error.localizedDescription),
                manifest: nil,
                current: currentVersion
            )
        }

        guard let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data) else {
            return UpdateCheckResult(
                status: .couldNotCheck(reason: "The update file on GitHub is not readable."),
                manifest: nil,
                current: currentVersion
            )
        }

        return UpdateCheckResult(
            status: UpdateComparison.evaluate(
                manifest: manifest,
                current: currentVersion,
                osVersion: osVersion
            ),
            manifest: manifest,
            current: currentVersion
        )
    }

    /// Cache is bypassed deliberately. The manifest is a few hundred bytes and
    /// GitHub's CDN will happily serve a five-minute-old copy — which, on the
    /// day of a release, is exactly the copy that says there is no update.
    public static let httpsFetch: Fetcher = { url in
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateFetchError.badStatus(http.statusCode)
        }
        return data
    }

    public static func runningOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

public enum UpdateFetchError: Error, LocalizedError, Equatable {
    case badStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .badStatus(404):
            // The single most likely misconfiguration, and the one whose
            // generic message sends people debugging the app instead of the
            // repo.
            return "No update file published yet (404)."
        case .badStatus(let code):
            return "GitHub answered \(code)."
        }
    }
}

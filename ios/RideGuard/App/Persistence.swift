import Foundation
import RideGuardCore

// Storage for the two things worth keeping: what the driver configured, and
// what the driver evaluated.
//
// No Core Data. The settings are one small struct and the history is an append
// -mostly list that a heavy shift grows by maybe forty rows; a JSON file read
// once at launch is faster than the Core Data stack that would manage it, and
// it is inspectable from the Files app when a driver reports a wrong number.

/// Where shared state lives.
///
/// The App Group is not optional dressing: the share extension runs in a
/// SEPARATE PROCESS with its own container. Without the group it would read an
/// empty vehicle profile, charge 0 RON/km of fuel, and cheerfully call a
/// loss-making offer green. Both targets must carry this entitlement.
public enum Persistence {
    public static let appGroupIdentifier = "group.com.priemschi.rideguard.shared"

    /// Falls back to the process-local store so the app still runs in a
    /// simulator build without the entitlement wired up — the extension is the
    /// only thing that breaks, and it breaks visibly.
    public static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    public static var isAppGroupAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) != nil
    }

    /// Application Support inside the App Group container, so both processes
    /// see one history file. Directory is created on demand.
    ///
    /// `public` because `HistoryStore.init` is public and defaults its `url` to
    /// this. A default argument on public API is serialised for callers to
    /// evaluate, so everything it touches must be public too — internal here is
    /// a compile error, not a style preference.
    public static func supportDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Library/Application Support/RideGuard", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]  // readable when a driver mails us the file
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension KeyedDecodingContainer {
    /// Absent, null, or the wrong type all read as nil, so one bad field costs
    /// one field rather than the whole settings blob.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

// MARK: - Settings

/// Everything the driver configured. One value, one blob, one write.
///
/// `Sendable` because the share extension hands it to a detached task that
/// runs Vision off the main actor.
public struct AppSettings: Codable, Equatable, Sendable {
    public var vehicle: VehicleProfile
    public var thresholds: DriverThresholds
    /// Keyed by `Platform.rawValue` rather than by `Platform` so the JSON stays
    /// a plain object; Swift encodes non-String-keyed dictionaries as a flat
    /// alternating array, which is unreadable and awkward to migrate.
    ///
    /// There is deliberately no commission setting beside this one. Both
    /// Romanian driver apps print the driver's NET take on the card, so there
    /// is nothing to subtract; offering a commission slider invites a driver to
    /// set one and be wrong by that percentage on every single offer.
    public var fareIsNetFlags: [String: Bool]
    /// Which app the driver mostly works. Used as the tie-break when a shared
    /// screenshot gives no clue which platform it came from.
    public var defaultPlatform: Platform
    public var hasCompletedOnboarding: Bool
    /// Whether a verdict is mirrored onto the Lock Screen after it is
    /// computed. Off by default: it is the one feature here that can put
    /// something on the driver's screen without being asked.
    public var liveActivityEnabled: Bool

    public init(
        vehicle: VehicleProfile = .defaultRO,
        thresholds: DriverThresholds = DriverThresholds(),
        fareIsNetFlags: [String: Bool] = [:],
        defaultPlatform: Platform = .bolt,
        hasCompletedOnboarding: Bool = false,
        liveActivityEnabled: Bool = false
    ) {
        self.vehicle = vehicle
        self.thresholds = thresholds
        self.fareIsNetFlags = fareIsNetFlags
        self.defaultPlatform = defaultPlatform
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.liveActivityEnabled = liveActivityEnabled
    }

    /// Hand-written so that adding a field in a later build does not throw on
    /// a blob written by an earlier one. Synthesised decoding treats a missing
    /// key as an error, `SettingsStore` treats an error as "start fresh", and
    /// the driver would silently lose their car and their targets on update —
    /// on a build that updates itself from GitHub, that is not hypothetical.
    public enum CodingKeys: String, CodingKey {
        case vehicle, thresholds, fareIsNetFlags, defaultPlatform, hasCompletedOnboarding, liveActivityEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings()
        vehicle = c.lenient(VehicleProfile.self, .vehicle) ?? fallback.vehicle
        thresholds = c.lenient(DriverThresholds.self, .thresholds) ?? fallback.thresholds
        fareIsNetFlags = c.lenient([String: Bool].self, .fareIsNetFlags) ?? [:]
        defaultPlatform = c.lenient(Platform.self, .defaultPlatform) ?? fallback.defaultPlatform
        hasCompletedOnboarding = c.lenient(Bool.self, .hasCompletedOnboarding) ?? false
        liveActivityEnabled = c.lenient(Bool.self, .liveActivityEnabled) ?? false
    }

    public func fareIsNet(for platform: Platform) -> Bool {
        fareIsNetFlags[platform.rawValue] ?? platform.fareShownIsNetByDefault
    }

    public mutating func setFareIsNet(_ value: Bool, for platform: Platform) {
        fareIsNetFlags[platform.rawValue] = value
    }
}

public struct SettingsStore {
    private let key = "rideguard.settings.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = Persistence.defaults) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        guard
            let data = defaults.data(forKey: key),
            let settings = try? Persistence.decoder.decode(AppSettings.self, from: data)
        else {
            // A decode failure means a shape change we did not migrate. Falling
            // back to defaults loses configuration, which the driver will
            // notice and can fix in a minute; crashing loses the shift.
            return AppSettings()
        }
        return settings
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? Persistence.encoder.encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - Quick entry

/// The last legs the driver typed, so the next offer is fewer taps.
///
/// The fare is deliberately NOT remembered. Distances and times repeat — the
/// same driver works the same patch and types "3" and "10" all evening — but
/// the fare is different every single time, and a prefilled fare is how a
/// driver ends up looking at a verdict for the previous offer.
///
/// Stored as the raw strings rather than as `Double`s so "2,4" comes back as
/// "2,4" and not as "2.4" on a phone set to English.
public struct QuickEntryDraft: Codable, Equatable, Sendable {
    public var platform: Platform
    public var pickupKm: String
    public var pickupMin: String
    public var tripKm: String
    public var tripMin: String

    public init(
        platform: Platform = .bolt,
        pickupKm: String = "",
        pickupMin: String = "",
        tripKm: String = "",
        tripMin: String = ""
    ) {
        self.platform = platform
        self.pickupKm = pickupKm
        self.pickupMin = pickupMin
        self.tripKm = tripKm
        self.tripMin = tripMin
    }

    public var hasLegs: Bool {
        ![pickupKm, pickupMin, tripKm, tripMin].allSatisfy(\.isEmpty)
    }

    /// One line for the "reuse" chip: short enough for a thumb-sized button.
    public var summary: String {
        let pickup = [pickupKm.isEmpty ? "—" : pickupKm + " km", pickupMin.isEmpty ? nil : pickupMin + " min"]
            .compactMap { $0 }.joined(separator: " · ")
        let trip = [tripKm.isEmpty ? "—" : tripKm + " km", tripMin.isEmpty ? nil : tripMin + " min"]
            .compactMap { $0 }.joined(separator: " · ")
        return "\(pickup) → \(trip)"
    }
}

public struct QuickEntryDraftStore {
    private let key = "rideguard.quickentry.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = Persistence.defaults) {
        self.defaults = defaults
    }

    public func load() -> QuickEntryDraft? {
        guard
            let data = defaults.data(forKey: key),
            let draft = try? Persistence.decoder.decode(QuickEntryDraft.self, from: data)
        else { return nil }
        return draft
    }

    public func save(_ draft: QuickEntryDraft) {
        guard let data = try? Persistence.encoder.encode(draft) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - History

/// One evaluated offer, flattened.
///
/// Flattened rather than storing the whole `OfferEconomics` because history
/// outlives code: a row written today must still render after the calculator
/// gains a field. Everything the list and the shift totals need is here.
public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {

    public enum Source: String, Codable, Sendable {
        case manual = "MANUAL"
        /// Written by the share extension, which no longer exists. Kept because
        /// history outlives code: a driver upgrading has rows on disk with this
        /// value, and removing the case would make the decoder throw on the
        /// whole file — losing his history to save one line.
        case screenshot = "SCREENSHOT"

        public var displayName: String {
            switch self {
            case .manual: return "Typed"
            case .screenshot: return "Screenshot"
            }
        }
    }

    /// What the driver did about it. Recorded separately from the verdict,
    /// because the interesting number after a week is how often they overrode
    /// the app — and whether they were right to.
    public enum Decision: String, Codable, Sendable {
        case undecided = "UNDECIDED"
        case accepted = "ACCEPTED"
        case declined = "DECLINED"
    }

    public let id: UUID
    public let capturedAt: Date
    public let platform: Platform
    public let currency: String
    public let fare: Double
    public let gross: Double
    public let net: Double
    public let totalKm: Double
    public let totalMin: Double?
    public let netPerKm: Double
    public let netPerHour: Double?
    public let deadheadRatio: Double?
    public let verdict: Verdict
    public let source: Source
    public var decision: Decision

    public init(economics: OfferEconomics, source: Source, decision: Decision = .undecided, id: UUID = UUID()) {
        self.id = id
        // `capturedAtMs` is 0 for a hand-typed offer, so fall back to now.
        self.capturedAt = economics.offer.capturedAtMs > 0
            ? Date(timeIntervalSince1970: Double(economics.offer.capturedAtMs) / 1000.0)
            : Date()
        self.platform = economics.offer.platform
        self.currency = economics.currency
        self.fare = economics.offer.fare
        self.gross = economics.gross
        self.net = economics.net
        self.totalKm = economics.totalKm
        self.totalMin = economics.totalMin
        self.netPerKm = economics.netPerKm
        self.netPerHour = economics.netPerHour
        self.deadheadRatio = economics.deadheadRatio
        self.verdict = economics.verdict
        self.source = source
        self.decision = decision
    }
}

/// Totals for a set of entries. Deliberately counts only ACCEPTED rides for
/// the money figures: a shift's earnings are what the driver drove, not what
/// they were offered.
public struct ShiftSummary: Equatable {
    public var evaluated: Int = 0
    public var accepted: Int = 0
    public var declined: Int = 0
    public var netEarned: Double = 0
    public var kmDriven: Double = 0
    public var minutesWorked: Double = 0
    public var currency: String = "RON"

    public var netPerHour: Double? {
        guard minutesWorked > 0 else { return nil }
        return netEarned / (minutesWorked / 60.0)
    }

    public var netPerKm: Double? {
        guard kmDriven > 0 else { return nil }
        return netEarned / kmDriven
    }

    public init(entries: [HistoryEntry]) {
        currency = entries.first?.currency ?? "RON"
        for entry in entries {
            evaluated += 1
            switch entry.decision {
            case .accepted:
                accepted += 1
                netEarned += entry.net
                kmDriven += entry.totalKm
                minutesWorked += entry.totalMin ?? 0
            case .declined:
                declined += 1
            case .undecided:
                break
            }
        }
    }
}

public struct HistoryStore {
    /// Anything older than this is noise, and an unbounded file eventually
    /// costs a slow launch. Roughly two months of hard driving.
    private let maxEntries = 2_000
    private let url: URL

    public init(url: URL = Persistence.supportDirectory().appendingPathComponent("history.json")) {
        self.url = url
    }

    public func load() -> [HistoryEntry] {
        var data: Data?
        // Coordinated because the share extension is a second process writing
        // the same file. Without this, an append from the extension while the
        // app is reading can hand back a half-written file.
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            data = try? Data(contentsOf: url)
        }
        guard let data, let entries = try? Persistence.decoder.decode([HistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    public func save(_ entries: [HistoryEntry]) {
        let trimmed = Array(entries.sorted { $0.capturedAt > $1.capturedAt }.prefix(maxEntries))
        guard let data = try? Persistence.encoder.encode(trimmed) else { return }
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Read-modify-write under one coordination pass, so an append from the
    /// extension cannot clobber a concurrent append from the app.
    @discardableResult
    public func append(_ entry: HistoryEntry) -> [HistoryEntry] {
        mutate { $0.insert(entry, at: 0) }
    }

    /// Used by the share extension, which logs the offer the moment it has a
    /// verdict and then amends the decision if the driver taps took/skipped.
    @discardableResult
    public func updateDecision(_ decision: HistoryEntry.Decision, for id: UUID) -> [HistoryEntry] {
        mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].decision = decision
        }
    }

    @discardableResult
    private func mutate(_ change: (inout [HistoryEntry]) -> Void) -> [HistoryEntry] {
        var result: [HistoryEntry] = []
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { url in
            var entries: [HistoryEntry] = []
            if let data = try? Data(contentsOf: url) {
                entries = (try? Persistence.decoder.decode([HistoryEntry].self, from: data)) ?? []
            }
            change(&entries)
            entries = Array(entries.sorted { $0.capturedAt > $1.capturedAt }.prefix(maxEntries))
            if let data = try? Persistence.encoder.encode(entries) {
                try? data.write(to: url, options: .atomic)
            }
            result = entries
        }
        return result
    }
}

import Foundation
import Combine
import RideGuardCore

/// The app's single source of truth: settings, history, and the one method
/// that turns numbers into a verdict.
///
/// `ObservableObject` rather than `@Observable` because this same type — and
/// more importantly the stores behind it — is compiled into the share
/// extension, which has no `App` scene to hang an observation registrar off,
/// and because `@Published` + `didSet` gives write-through persistence in one
/// line. One mechanism everywhere beats two.
@MainActor
final class AppState: ObservableObject {

    /// Every mutation is persisted immediately. Settings are a few hundred
    /// bytes and `UserDefaults` batches its own disk writes, so this is
    /// cheaper than the "save on background" dance it replaces — and a driver
    /// who force-quits mid-shift keeps their configuration.
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsStore.save(settings)
        }
    }

    @Published private(set) var history: [HistoryEntry] = []

    private let settingsStore: SettingsStore
    private let historyStore: HistoryStore

    init(settingsStore: SettingsStore = SettingsStore(), historyStore: HistoryStore = HistoryStore()) {
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.settings = settingsStore.load()
        self.history = historyStore.load()
    }

    // MARK: - Evaluation

    /// No commission override is passed: every platform defaults to zero
    /// because both Romanian driver apps show the driver's own net take. The
    /// calculator still models commission for markets where the card is gross,
    /// which is what `fareIsNet` selects between.
    var calculator: ProfitCalculator {
        ProfitCalculator(vehicle: settings.vehicle, thresholds: settings.thresholds)
    }

    func evaluate(_ offer: RideOffer) -> OfferEconomics? {
        calculator.evaluate(offer)
    }

    /// Builds an offer from hand-typed values. `fareIsNet` is never asked at
    /// entry time: it is a property of the platform's UI, not of this ride, so
    /// it belongs in settings where the driver sets it once against a real
    /// payout statement.
    func makeOffer(
        platform: Platform,
        fare: Double,
        pickupKm: Double?,
        pickupMin: Double?,
        tripKm: Double?,
        tripMin: Double?
    ) -> RideOffer {
        RideOffer(
            platform: platform,
            fare: fare,
            currency: settings.vehicle.currency,
            pickupKm: pickupKm,
            pickupMin: pickupMin,
            tripKm: tripKm,
            tripMin: tripMin,
            fareIsNet: settings.fareIsNet(for: platform),
            capturedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            // Typed by a human, so nothing was guessed: full confidence, and
            // the UNKNOWN verdict can never fire on this path.
            parseConfidence: 1
        )
    }

    // MARK: - History

    @discardableResult
    func log(_ economics: OfferEconomics, source: HistoryEntry.Source, decision: HistoryEntry.Decision = .undecided) -> HistoryEntry {
        let entry = HistoryEntry(economics: economics, source: source, decision: decision)
        history = historyStore.append(entry)
        return entry
    }

    func setDecision(_ decision: HistoryEntry.Decision, for entryID: UUID) {
        guard let index = history.firstIndex(where: { $0.id == entryID }) else { return }
        history[index].decision = decision
        historyStore.save(history)
    }

    func delete(_ entries: [HistoryEntry]) {
        let ids = Set(entries.map(\.id))
        history.removeAll { ids.contains($0.id) }
        historyStore.save(history)
    }

    func clearHistory() {
        history = []
        historyStore.save(history)
    }

    /// Called when the app comes back to the foreground.
    ///
    /// The share extension is a different process: anything the driver
    /// analysed from the share sheet was written to the shared file while this
    /// process was suspended, and this is the only way it ever appears in the
    /// list.
    func reloadFromDisk() {
        let stored = historyStore.load()
        if stored != history { history = stored }
        let storedSettings = settingsStore.load()
        if storedSettings != settings { settings = storedSettings }
    }

    // MARK: - Shift totals

    func entries(on date: Date, calendar: Calendar = .current) -> [HistoryEntry] {
        history.filter { calendar.isDate($0.capturedAt, inSameDayAs: date) }
    }

    var todaySummary: ShiftSummary {
        ShiftSummary(entries: entries(on: Date()))
    }

    /// Days that have at least one entry, newest first. Drives the section
    /// list in History.
    func days(calendar: Calendar = .current) -> [Date] {
        var seen = Set<Date>()
        var out: [Date] = []
        for entry in history.sorted(by: { $0.capturedAt > $1.capturedAt }) {
            let day = calendar.startOfDay(for: entry.capturedAt)
            if seen.insert(day).inserted { out.append(day) }
        }
        return out
    }

    // MARK: - Onboarding

    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
    }
}

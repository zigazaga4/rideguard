import Foundation

/// The verdict, in transit between two processes.
///
/// ## Why this file exists
///
/// The screen reader and the thing that draws the overlay **cannot** live in
/// the same process on iOS. ReplayKit delivers frames only to a Broadcast
/// Upload Extension, and that extension cannot present UI over other apps. The
/// app can present a floating window (via Picture-in-Picture) but can never see
/// the screen. So the work is split across a process boundary that iOS gives us
/// no choice about, and this type is what crosses it.
///
/// ## Why a file plus a Darwin notification
///
/// App extensions and their host app share a container but nothing else — no
/// shared memory, no XPC, no `NotificationCenter`. The two mechanisms that do
/// cross the boundary are the App Group container and Darwin notifications, and
/// each is missing what the other has: Darwin notifications carry **no
/// payload**, and a file on disk produces **no signal** when it changes.
/// Together they work: write the payload, then post the name.
///
/// `UserDefaults(suiteName:)` is deliberately not used for this. It is fine for
/// settings, but it caches aggressively across processes and there is no
/// supported way to force a cross-process reload — which shows up as a HUD
/// frozen on the previous ride's numbers.
public struct LiveVerdict: Codable, Equatable, Sendable {

    /// Monotonic per broadcast session. The overlay drops anything not newer
    /// than what it is already showing, so a frame that arrives late — which
    /// happens whenever OCR runs long — cannot repaint a stale number over a
    /// fresh one.
    public let sequence: UInt64

    /// False when the offer card left the screen. The overlay hides rather than
    /// leaving the last verdict floating over an unrelated screen, which would
    /// read as a live recommendation.
    public let visible: Bool

    /// Headline: what the ride pays per kilometre driven, commission removed.
    public let earningsPerKm: Double
    /// The same figure after fuel. What he actually keeps.
    public let netPerKm: Double
    /// `GOOD` / `MARGINAL` / `BAD` / `UNKNOWN`. A string, not the enum, so a
    /// version skew between the two processes degrades to "unknown" instead of
    /// failing to decode the whole payload.
    public let verdict: String
    public let currency: String
    public let totalKm: Double
    public let netPerHour: Double?
    /// pickupKm ÷ tripKm. Nil when either leg was unreadable.
    public let deadheadRatio: Double?
    /// `bolt` / `uber` / `unknown`.
    public let platform: String
    public let capturedAtMs: Int64

    public init(
        sequence: UInt64,
        visible: Bool,
        earningsPerKm: Double,
        netPerKm: Double,
        verdict: String,
        currency: String,
        totalKm: Double,
        netPerHour: Double?,
        deadheadRatio: Double?,
        platform: String,
        capturedAtMs: Int64
    ) {
        self.sequence = sequence
        self.visible = visible
        self.earningsPerKm = earningsPerKm
        self.netPerKm = netPerKm
        self.verdict = verdict
        self.currency = currency
        self.totalKm = totalKm
        self.netPerHour = netPerHour
        self.deadheadRatio = deadheadRatio
        self.platform = platform
        self.capturedAtMs = capturedAtMs
    }

    /// Sent when the offer card disappears. Carries no numbers on purpose —
    /// there is nothing true to say about a card that is no longer there.
    public static func hidden(sequence: UInt64) -> LiveVerdict {
        LiveVerdict(
            sequence: sequence,
            visible: false,
            earningsPerKm: 0, netPerKm: 0,
            verdict: "UNKNOWN", currency: "",
            totalKm: 0, netPerHour: nil, deadheadRatio: nil,
            platform: "unknown",
            capturedAtMs: 0
        )
    }
}

/// Moves a `LiveVerdict` between the broadcast extension and the app.
public enum LiveVerdictChannel {

    /// Must match every `.entitlements` file. See `Persistence.appGroupIdentifier`.
    public static let appGroupIdentifier = "group.com.rideguard.shared"

    /// Darwin notification names are a global namespace shared with every
    /// process on the device, so this is reverse-DNS to avoid a collision.
    public static let notificationName = "com.rideguard.liveverdict"

    private static let fileName = "live-verdict.json"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(fileName)
    }

    // MARK: - Writing (broadcast extension side)

    /// Writes the payload, then signals. Never throws.
    ///
    /// Order matters and is not interchangeable: the notification must be the
    /// *last* thing, because a reader woken before the bytes land reads the
    /// previous verdict and we lose an update with no error anywhere.
    @discardableResult
    public static func publish(_ verdict: LiveVerdict) -> Bool {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(verdict) else { return false }

        // .atomic writes to a temp file and renames. Without it the reader can
        // catch a half-written file and fail to decode — rare on a small
        // payload, but this runs many times a minute for a whole shift.
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }

        notifyObservers()
        return true
    }

    private static func notifyObservers() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil,
            nil,
            true
        )
    }

    // MARK: - Reading (app side)

    public static func read() -> LiveVerdict? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LiveVerdict.self, from: data)
    }

    /// Clears the channel so a stale verdict cannot be read back at the start
    /// of the next session and shown as if it were live.
    public static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Observing

    /// Calls `onChange` on the main queue whenever a new verdict is published.
    ///
    /// The Darwin callback is a C function pointer and cannot capture context,
    /// so the handler is parked in a static. That is a real constraint of the
    /// API, not a shortcut — and it is why only one observer is supported,
    /// which is all the app needs.
    public static func observe(_ onChange: @escaping (LiveVerdict) -> Void) {
        handler = onChange

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                let latest = LiveVerdictChannel.read()
                DispatchQueue.main.async {
                    guard let latest else { return }
                    LiveVerdictChannel.handler?(latest)
                }
            },
            notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    public static func stopObserving() {
        handler = nil
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil
        )
    }

    nonisolated(unsafe) private static var handler: ((LiveVerdict) -> Void)?
}

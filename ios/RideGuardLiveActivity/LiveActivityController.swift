import Foundation
import RideGuardCore

#if canImport(ActivityKit)
import ActivityKit
#endif

//  Every entry point here is best-effort and silent on failure.
//
//  A Live Activity is a nice-to-have bolted onto the side of the app: it must
//  never be able to stop a verdict from being computed, shown or logged. So
//  nothing throws out of this file, nothing is awaited by the UI, and a device
//  with Live Activities switched off in Settings simply gets nothing.

/// Mirrors the most recent verdict onto the Lock Screen and Dynamic Island.
public enum LiveActivityController {

    /// Long enough to still be there when the driver looks down after
    /// accepting, short enough not to litter the Lock Screen for an hour.
    private static let staleAfter: TimeInterval = 10 * 60

    public static var isSupported: Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) { return true }
        return false
        #else
        return false
        #endif
    }

    /// True only when the OS AND the driver both allow it. Used to decide
    /// whether the settings toggle is worth showing at all.
    public static var isAvailable: Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        return false
        #else
        return false
        #endif
    }

    /// Replaces whatever is on screen with this verdict.
    ///
    /// Replace rather than update, because the interesting thing is always the
    /// LATEST offer: a driver comparing two Live Activities on a Lock Screen
    /// while driving is worse than no Live Activity at all.
    public static func show(_ economics: OfferEconomics, enabled: Bool) {
        guard enabled else { return }
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        endAll()

        let attributes = VerdictActivityAttributes(platformName: economics.offer.platform.displayName)
        let state = VerdictActivityAttributes.ContentState(economics: economics)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter))

        // Requesting a Live Activity from an app extension is not reliably
        // permitted on every OS version, and the failure is a thrown error
        // rather than a crash. Swallowing it is correct: the share sheet has
        // already shown the driver the verdict, which is the part that matters.
        _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
        #endif
    }

    public static func endAll() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<VerdictActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        #endif
    }
}

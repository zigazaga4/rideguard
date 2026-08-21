import Foundation
import RideGuardCore

#if canImport(ActivityKit)
import ActivityKit

//  The closest iOS gets to Android's floating HUD — and it is not very close.
//
//  A Live Activity renders on the Lock Screen and in the Dynamic Island, in a
//  layout the system owns, showing OUR data. It cannot float over the Bolt app
//  and it cannot appear because an offer arrived, because nothing tells us an
//  offer arrived. What it can do is keep the verdict the driver just computed
//  glanceable for a few minutes without unlocking the phone, which is worth
//  having and is exactly what it is sold as here.
//
//  This file is compiled into BOTH the app and the widget extension. Keep it
//  free of anything but Foundation, RideGuardCore and ActivityKit — a widget
//  extension has a hard memory budget and no business importing UI code.

/// A verdict, already reduced to what fits on a Lock Screen.
///
/// Pre-formatted strings rather than raw `Double`s: the numbers are formatted
/// once, by the same `NumberParsing` the verdict card uses, so the Lock Screen
/// can never round differently from the card the driver just looked at. The
/// content state is also serialised across a process boundary on every update,
/// and strings keep that payload small.
@available(iOS 16.1, *)
public struct VerdictActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        public var verdict: Verdict
        public var netText: String
        public var perKmText: String
        public var perHourText: String?
        public var distanceText: String

        public init(
            verdict: Verdict,
            netText: String,
            perKmText: String,
            perHourText: String?,
            distanceText: String
        ) {
            self.verdict = verdict
            self.netText = netText
            self.perKmText = perKmText
            self.perHourText = perHourText
            self.distanceText = distanceText
        }
    }

    /// Which app the offer came from. Fixed for the life of the activity.
    public var platformName: String

    public init(platformName: String) {
        self.platformName = platformName
    }
}

@available(iOS 16.1, *)
public extension VerdictActivityAttributes.ContentState {
    /// One place that turns economics into Lock Screen text, so every surface
    /// that shows this activity says the same thing.
    init(economics: OfferEconomics) {
        self.init(
            verdict: economics.verdict,
            netText: NumberParsing.formatMoney(economics.net, currency: economics.currency),
            perKmText: "\(NumberParsing.formatRate(economics.netPerKm)) \(economics.currency)/km",
            perHourText: economics.netPerHour.map {
                "\(NumberParsing.formatRate($0, decimals: 0)) \(economics.currency)/h"
            },
            distanceText: "\(NumberParsing.formatRate(economics.totalKm, decimals: 1)) km total"
        )
    }
}

#endif

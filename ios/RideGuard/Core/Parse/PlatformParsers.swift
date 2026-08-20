import Foundation

/// Bolt Driver — `ee.mtakso.driver`
/// (Bolt was formerly Taxify, an Estonian company: hence the `ee` / `mtakso`.)
///
/// TUNING NOTE: the keyword and product lists below are the first thing to
/// adjust once real fixtures land. On iOS the fixtures come from shared
/// screenshots run through Vision, so collecting them costs a driver one tap
/// per offer — tighten these against the actual strings Bolt renders in your
/// market and language.
public final class BoltOfferParser: HeuristicOfferParser {

    private let products = [
        "Comfort", "XL", "Green", "Pet", "Assist", "Business", "Bolt Plus", "Economy", "Send",
    ]

    public init(hints: ParserHints = ParserHints(
        offerKeywords: ParserHints.defaultOfferKeywords + [
            "bolt", "comandă nouă", "cursă nouă", "new order", "new ride",
        ]
    )) {
        super.init(platform: .bolt, hints: hints)
    }

    public override func detectProduct(_ snapshot: ScreenSnapshot) -> String? {
        let text = snapshot.flatText
        return products.first { text.range(of: $0, options: .caseInsensitive) != nil }
    }
}

/// Uber Driver — `com.ubercab.driver`
///
/// Uber's card usually reads "N min (X km) away" for the deadhead leg and
/// "M min (Y km) trip" for the paid leg, which the shared reading-order
/// heuristic already handles correctly. Uber also tends to show the fare
/// NET of commission, unlike Bolt — see `Platform.fareShownIsNetByDefault`.
public final class UberOfferParser: HeuristicOfferParser {

    private let products = [
        "UberX", "Comfort", "Green", "Black", "XL", "Pet", "Pool", "Connect", "Share", "Taxi",
    ]

    public init(hints: ParserHints = ParserHints(
        offerKeywords: ParserHints.defaultOfferKeywords + [
            "uber", "exclusive", "match", "surge", "promotion", "include",
        ]
    )) {
        super.init(platform: .uber, hints: hints)
    }

    public override func detectProduct(_ snapshot: ScreenSnapshot) -> String? {
        let text = snapshot.flatText
        return products.first { text.range(of: $0, options: .caseInsensitive) != nil }
    }
}

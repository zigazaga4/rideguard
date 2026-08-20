import Foundation

/// A meaningful value lifted out of a text block, with the block it came from
/// so we can still reason about WHERE on screen it was.
///
/// Kotlin models this as a sealed interface; the Swift equivalent is an enum
/// with one payload struct per case. The payload structs (rather than bare
/// associated values) exist so `pickFare` can hand a whole `Token.Money`
/// around, exactly as the Kotlin does.
public enum Token: Equatable, Sendable {

    public struct Money: Equatable, Sendable {
        public let value: Double
        public let currency: String
        public let source: TextBlock
        public init(value: Double, currency: String, source: TextBlock) {
            self.value = value
            self.currency = currency
            self.source = source
        }
    }

    public struct Distance: Equatable, Sendable {
        public let km: Double
        public let source: TextBlock
        public init(km: Double, source: TextBlock) {
            self.km = km
            self.source = source
        }
    }

    public struct Duration: Equatable, Sendable {
        public let minutes: Double
        public let source: TextBlock
        public init(minutes: Double, source: TextBlock) {
            self.minutes = minutes
            self.source = source
        }
    }

    public struct Rating: Equatable, Sendable {
        public let stars: Double
        public let source: TextBlock
        public init(stars: Double, source: TextBlock) {
            self.stars = stars
            self.source = source
        }
    }

    public struct Multiplier: Equatable, Sendable {
        public let factor: Double
        public let source: TextBlock
        public init(factor: Double, source: TextBlock) {
            self.factor = factor
            self.source = source
        }
    }

    case money(Money)
    case distance(Distance)
    case duration(Duration)
    case rating(Rating)
    case multiplier(Multiplier)

    public var source: TextBlock {
        switch self {
        case .money(let t): return t.source
        case .distance(let t): return t.source
        case .duration(let t): return t.source
        case .rating(let t): return t.source
        case .multiplier(let t): return t.source
        }
    }

    // Kotlin gets `filterIsInstance<Token.Money>()` for free; these accessors
    // are the Swift stand-in and keep the call sites just as readable.
    public var asMoney: Money? { if case .money(let t) = self { return t }; return nil }
    public var asDistance: Distance? { if case .distance(let t) = self { return t }; return nil }
    public var asDuration: Duration? { if case .duration(let t) = self { return t }; return nil }
    public var asRating: Rating? { if case .rating(let t) = self { return t }; return nil }
    public var asMultiplier: Multiplier? { if case .multiplier(let t) = self { return t }; return nil }
}

/// Pulls typed tokens out of raw on-screen text.
///
/// Shared by every platform parser — Bolt and Uber format their cards
/// differently but they both write money as money and kilometres as
/// kilometres, so the scanning is common and only the ASSEMBLY differs.
///
/// Two deliberate ICU-vs-Java notes, since these patterns are ports:
///  - ICU's case-insensitivity is Unicode-aware where Java's is ASCII-only,
///    so `ORĂ` and `км` match here and would not on Android. That can only
///    add correct matches, never wrong ones, so it is left alone.
///  - Everything else — greediness, alternation order, non-overlapping scan
///    order — behaves identically, which is what keeps the two apps in sync.
public enum TokenScanner {

    /// Currency markers seen across Bolt/Uber markets. Order matters: longest first.
    private static let currencyAlternation =
        "lei|RON|EUR|USD|GBP|PLN|CZK|HUF|UAH|GEL|KZT|BGN|RSD|MDL|TRY|CHF|SEK|NOK|DKK|"
        + "zł|Kč|Ft|лв|din|₴|₾|₸|₺|€|\\$|£|kr"

    private static let currencyNames: [String: String] = [
        "lei": "RON", "ron": "RON",
        "€": "EUR", "eur": "EUR",
        "$": "USD", "usd": "USD",
        "£": "GBP", "gbp": "GBP",
        "zł": "PLN", "pln": "PLN",
        "kč": "CZK", "czk": "CZK",
        "ft": "HUF", "huf": "HUF",
        "₴": "UAH", "uah": "UAH",
        "₾": "GEL", "gel": "GEL",
        "₸": "KZT", "kzt": "KZT",
        "₺": "TRY", "try": "TRY",
        "лв": "BGN", "bgn": "BGN",
        "din": "RSD", "rsd": "RSD",
        "mdl": "MDL",
    ]

    /// Digits plus the separators a number may contain mid-run.
    ///
    /// NOTE the asymmetry with `NumberParsing.numericRun`, which also accepts
    /// U+00A0/U+202F/U+2009/U+2007. The Kotlin has plain spaces here and the
    /// exotic ones there, so `1<NBSP>234,5 lei` tokenises as 234.5 on Android.
    /// Reproduced rather than fixed: parity with the shipped Android build
    /// matters more than this edge case, and fixing it belongs in the Kotlin
    /// first so both stay identical.
    private static let num = "\\d[\\d., ]*"

    private static let moneySymbolFirst =
        CompiledRegex("(\(currencyAlternation))\\s*(\(num))", ignoreCase: true)
    private static let moneySymbolLast =
        CompiledRegex("(\(num))\\s*(\(currencyAlternation))", ignoreCase: true)

    private static let km = CompiledRegex("(\(num))\\s*(?:km|КМ)\\b", ignoreCase: true)

    /// Metres — `m` not followed by `in`/`i`, so we never eat "min" or "mi".
    private static let metres = CompiledRegex("(\(num))\\s*m(?![a-z])", ignoreCase: true)
    private static let miles = CompiledRegex("(\(num))\\s*(?:mi|miles?)\\b", ignoreCase: true)

    private static let hoursAndMinutes = CompiledRegex(
        "(\\d+)\\s*(?:h|hr|hrs|hour|hours|ore|oră)\\s*(\\d+)\\s*(?:m|min|mins|minute|minutes)?\\b",
        ignoreCase: true
    )
    private static let minutes = CompiledRegex(
        "(\\d+)\\s*(?:min|mins|minute|minutes|minut|minute)\\b",
        ignoreCase: true
    )
    private static let hoursOnly = CompiledRegex(
        "(\\d+)\\s*(?:h|hr|hrs|hour|hours|ore|oră)\\b",
        ignoreCase: true
    )

    private static let rating =
        CompiledRegex("(?:★|⭐)\\s*(\\d[.,]\\d{1,2})|(\\d[.,]\\d{1,2})\\s*(?:★|⭐)")
    private static let bareRating = CompiledRegex("\\b([45][.,]\\d{1,2})\\b")
    private static let multiplier = CompiledRegex(
        "(\\d(?:[.,]\\d{1,2})?)\\s*[x×]|[x×]\\s*(\\d(?:[.,]\\d{1,2})?)",
        ignoreCase: true
    )

    public static func scan(_ snapshot: ScreenSnapshot) -> [Token] {
        snapshot.inReadingOrder.flatMap { scanBlock($0) }
    }

    public static func scanBlock(_ block: TextBlock) -> [Token] {
        let text = block.text
        if text.isEmpty || text.allSatisfy(\.isWhitespace) { return [] }

        var tokens: [Token] = []
        tokens += scanMoney(text, block).map(Token.money)
        tokens += scanDistance(text, block).map(Token.distance)
        tokens += scanDuration(text, block).map(Token.duration)
        tokens += scanRating(text, block).map(Token.rating)
        tokens += scanMultiplier(text, block).map(Token.multiplier)
        return tokens
    }

    private static func scanMoney(_ text: String, _ block: TextBlock) -> [Token.Money] {
        var out: [Token.Money] = []
        // "12,50 lei" matches both patterns. Whichever fires first claims the
        // span so the fare is not counted twice.
        var claimed: [Range<Int>] = []

        func consider(_ range: Range<Int>, numberPart: String, currencyPart: String) {
            let overlaps = claimed.contains { $0.lowerBound < range.upperBound && range.lowerBound < $0.upperBound }
            if overlaps { return }
            guard let value = NumberParsing.parseDecimal(numberPart) else { return }
            claimed.append(range)
            out.append(Token.Money(value: value, currency: normalizeCurrency(currencyPart), source: block))
        }

        for m in moneySymbolFirst.allMatches(text) {
            consider(m.range, numberPart: m.group(2), currencyPart: m.group(1))
        }
        for m in moneySymbolLast.allMatches(text) {
            consider(m.range, numberPart: m.group(1), currencyPart: m.group(2))
        }
        return out
    }

    private static func scanDistance(_ text: String, _ block: TextBlock) -> [Token.Distance] {
        let kmHits = km.allMatches(text).compactMap { m in
            NumberParsing.parseDecimal(m.group(1)).map { Token.Distance(km: $0, source: block) }
        }
        if !kmHits.isEmpty { return kmHits }

        let mileHits = miles.allMatches(text).compactMap { m in
            NumberParsing.parseDecimal(m.group(1)).map { Token.Distance(km: $0 * 1.609344, source: block) }
        }
        if !mileHits.isEmpty { return mileHits }

        return metres.allMatches(text).compactMap { m in
            NumberParsing.parseDecimal(m.group(1)).map { Token.Distance(km: $0 / 1000.0, source: block) }
        }
    }

    private static func scanDuration(_ text: String, _ block: TextBlock) -> [Token.Duration] {
        if let m = hoursAndMinutes.firstMatch(text) {
            let h = Double(m.group(1)) ?? 0.0
            let mm = Double(m.group(2)) ?? 0.0
            return [Token.Duration(minutes: h * 60 + mm, source: block)]
        }
        let mins = minutes.allMatches(text).compactMap { m in
            Double(m.group(1)).map { Token.Duration(minutes: $0, source: block) }
        }
        if !mins.isEmpty { return mins }

        return hoursOnly.allMatches(text).compactMap { m in
            Double(m.group(1)).map { Token.Duration(minutes: $0 * 60, source: block) }
        }
    }

    private static func scanRating(_ text: String, _ block: TextBlock) -> [Token.Rating] {
        if let m = rating.firstMatch(text) {
            let raw = m.group(1).isEmpty ? m.group(2) : m.group(1)
            if let value = NumberParsing.parseDecimal(raw) {
                return [Token.Rating(stars: value, source: block)]
            }
        }
        // Only accept a bare 4.xx/5.xx as a rating when the block is short —
        // otherwise "4,85 km" style text would masquerade as a star rating.
        // UTF-16 count, not grapheme count, to match Kotlin's String.length.
        if text.utf16.count <= 6, let m = bareRating.firstMatch(text) {
            if let value = NumberParsing.parseDecimal(m.group(1)), (1.0...5.0).contains(value) {
                return [Token.Rating(stars: value, source: block)]
            }
        }
        return []
    }

    private static func scanMultiplier(_ text: String, _ block: TextBlock) -> [Token.Multiplier] {
        multiplier.allMatches(text).compactMap { m in
            let raw = m.group(1).isEmpty ? m.group(2) : m.group(1)
            guard let value = NumberParsing.parseDecimal(raw), (1.0...10.0).contains(value) else { return nil }
            return Token.Multiplier(factor: value, source: block)
        }
    }

    private static func normalizeCurrency(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased()
        return currencyNames[key] ?? trimmed.uppercased()
    }
}

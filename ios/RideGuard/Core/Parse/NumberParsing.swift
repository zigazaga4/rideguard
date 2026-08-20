import Foundation

/// Locale-tolerant number parsing.
///
/// This exists because `Double("17,50")` returns nil and `Double("1.234")`
/// silently parses as 1.234 when the driver meant 1234. In Romania — where
/// Bolt is dominant — fares render as `17,50 lei` and distances as `2,4 km`.
/// Get this wrong and every downstream number is quietly, plausibly incorrect,
/// which is far worse than crashing.
///
/// `NumberFormatter` is deliberately NOT used: it is bound to a single locale
/// at a time, and the input here is whatever the driver app rendered, which
/// need not match the phone's locale (a Romanian driver with an English phone
/// still sees `17,50 lei`). The rules below are locale-free and match the
/// Kotlin implementation character for character.
///
/// Rules, applied in order:
///  1. Strip currency symbols, spaces, and thin/non-breaking spaces.
///  2. If BOTH `.` and `,` appear, the one that appears LAST is the decimal
///     separator and the other is grouping. Handles `1.234,56` and `1,234.56`.
///  3. If only one appears MORE THAN ONCE, it is grouping. `1.234.567`.
///  4. If only one appears ONCE, look at the digits after it:
///     exactly 3  -> grouping (`1.234` = 1234, the standard convention)
///     1 or 2     -> decimal  (`17,50` = 17.5, `2,4` = 2.4)
///     otherwise  -> decimal
public enum NumberParsing {

    /// U+00A0, U+202F, U+2009, U+2007 and the plain space. All five turn up as
    /// grouping separators in the wild; `1 234,5` must not become 1.
    private static let thinSpaces: [String] = ["\u{00a0}", "\u{202f}", "\u{2009}", "\u{2007}", " "]

    /// Grabs the first numeric-looking run out of arbitrary text.
    ///
    /// ICU's `\d` is Unicode-aware where Java's is ASCII-only. The difference
    /// is inert here: a Devanagari digit that ICU lets through fails the
    /// `Double(_:)` conversion at the end, so both platforms return nil.
    private static let numericRun = CompiledRegex(
        "-?\\d[\\d.,\u{00a0}\u{202f}\u{2009}\u{2007} ]*\\d|-?\\d"
    )

    /// Parse the first number found in `raw`, tolerating either decimal
    /// convention. Returns nil when there is no number at all.
    public static func parseDecimal(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty, !raw.allSatisfy(\.isWhitespace) else { return nil }
        guard let match = numericRun.firstMatch(raw) else { return nil }

        var s = match.value
        for space in thinSpaces { s = s.replacingOccurrences(of: space, with: "") }
        if s.isEmpty { return nil }

        let negative = s.hasPrefix("-")
        if negative { s.removeFirst() }

        // Character-index arithmetic, mirroring the Kotlin. Everything left
        // after the strip above is a digit or a separator, so there are no
        // grapheme-cluster surprises.
        let chars = Array(s)
        let lastDot = chars.lastIndex(of: ".")
        let lastComma = chars.lastIndex(of: ",")
        let dotCount = chars.filter { $0 == "." }.count
        let commaCount = chars.filter { $0 == "," }.count

        let normalized: String
        if let dot = lastDot, let comma = lastComma {
            // Both separators present: the later one is the decimal point.
            if dot > comma {
                normalized = s.replacingOccurrences(of: ",", with: "")
            } else {
                normalized = s
                    .replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: ",", with: ".")
            }
        } else if let dot = lastDot {
            if dotCount > 1 {
                normalized = s.replacingOccurrences(of: ".", with: "")
            } else if isGroupingByDigitCount(chars, separatorIndex: dot) {
                normalized = s.replacingOccurrences(of: ".", with: "")
            } else {
                normalized = s
            }
        } else if let comma = lastComma {
            if commaCount > 1 {
                normalized = s.replacingOccurrences(of: ",", with: "")
            } else if isGroupingByDigitCount(chars, separatorIndex: comma) {
                normalized = s.replacingOccurrences(of: ",", with: "")
            } else {
                normalized = s.replacingOccurrences(of: ",", with: ".")
            }
        } else {
            normalized = s
        }

        guard let value = Double(normalized) else { return nil }
        return negative ? -value : value
    }

    /// A lone separator with exactly three digits after it is a thousands
    /// separator by convention (`1.234`). One or two digits means decimals.
    private static func isGroupingByDigitCount(_ chars: [Character], separatorIndex: Int) -> Bool {
        let after = chars.count - separatorIndex - 1
        let before = separatorIndex
        return after == 3 && before > 0
    }

    /// Format for the verdict card. Deliberately terse — the card is small and
    /// the driver reads it in about two seconds.
    public static func formatMoney(_ value: Double, currency: String, decimals: Int = 2) -> String {
        let rounded = roundTo(value, decimals: decimals)
        let text = trimTrailingZeros(rounded, decimals: decimals)
        return "\(text) \(currency)"
    }

    public static func formatRate(_ value: Double, decimals: Int = 2) -> String {
        trimTrailingZeros(roundTo(value, decimals: decimals), decimals: decimals)
    }

    public static func roundTo(_ value: Double, decimals: Int) -> Double {
        var factor = 1.0
        for _ in 0..<max(0, decimals) { factor *= 10 }
        // Java's `Math.round` is half-UP (floor(x + 0.5)); Swift's `rounded()`
        // is half-away-from-zero. They disagree on negatives (-2.5 -> -2 vs
        // -3), and a loss-making offer is exactly where negatives show up, so
        // we spell out the Java behaviour to keep both apps on the same number.
        return (value * factor + 0.5).rounded(.down) / factor
    }

    private static func trimTrailingZeros(_ value: Double, decimals: Int) -> String {
        // No locale argument: `String(format:)` without one is POSIX, so the
        // separator is always `.`. Passing `Locale.current` would render
        // "17,50" on a Romanian phone and then the trimming below would eat
        // the wrong characters.
        var s = String(format: "%.\(max(0, decimals))f", value)
        guard s.contains(".") else { return s }
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

// MARK: - Regex plumbing

/// A tiny wrapper over `NSRegularExpression` that gives Kotlin's `Regex` API
/// shape: whole-match ranges in UTF-16 units and `groupValues`-style access
/// where an absent group reads as "".
///
/// `NSRegularExpression` rather than Swift's `Regex` type: the patterns here
/// are ICU patterns ported verbatim from Java, the module has to build for
/// anything that can import Foundation, and `NSRegularExpression`'s UTF-16
/// ranges line up exactly with Kotlin's `IntRange` match ranges — which the
/// money scanner relies on to detect overlapping matches.
struct CompiledRegex {
    private let regex: NSRegularExpression

    init(_ pattern: String, ignoreCase: Bool = false) {
        // Every pattern in this module is a compile-time constant. A failure
        // here is a programming error, not a runtime condition.
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: ignoreCase ? [.caseInsensitive] : []
        ) else {
            preconditionFailure("Invalid regex: \(pattern)")
        }
        self.regex = regex
    }

    func firstMatch(_ string: String) -> RegexMatch? {
        let ns = string as NSString
        guard let result = regex.firstMatch(
            in: string,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        ) else { return nil }
        return RegexMatch(result: result, in: ns)
    }

    func allMatches(_ string: String) -> [RegexMatch] {
        let ns = string as NSString
        return regex
            .matches(in: string, options: [], range: NSRange(location: 0, length: ns.length))
            .map { RegexMatch(result: $0, in: ns) }
    }
}

struct RegexMatch {
    /// UTF-16 offsets of the whole match, half-open. Kotlin's `MatchResult.range`
    /// is inclusive over the same units; the money scanner converts once.
    let range: Range<Int>
    let value: String
    private let groups: [String]

    init(result: NSTextCheckingResult, in ns: NSString) {
        self.range = result.range.location..<(result.range.location + result.range.length)
        self.value = ns.substring(with: result.range)
        self.groups = (0..<result.numberOfRanges).map { index in
            let r = result.range(at: index)
            // Kotlin's groupValues yields "" for a group that did not
            // participate; NSRange.location == NSNotFound is the same thing.
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    /// `group(0)` is the whole match, exactly like `groupValues`.
    func group(_ index: Int) -> String {
        index < groups.count ? groups[index] : ""
    }
}

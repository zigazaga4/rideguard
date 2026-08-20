import Foundation

/// Plain rectangle in screen pixels. Deliberately NOT `CGRect` —
/// this module must stay UI-framework-free so it can be tested without a
/// simulator, exactly like the Kotlin `:domain` module it mirrors.
///
/// Integer pixels rather than points, because the only producer on iOS is
/// Vision reading a screenshot, and screenshots are measured in pixels.
public struct Bounds: Equatable, Hashable, Sendable, Codable {
    public let left: Int
    public let top: Int
    public let right: Int
    public let bottom: Int

    public init(left: Int, top: Int, right: Int, bottom: Int) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var width: Int { right - left }
    public var height: Int { bottom - top }
    public var centerX: Int { (left + right) / 2 }
    public var centerY: Int { (top + bottom) / 2 }
    public var area: Int { max(0, width) * max(0, height) }

    public static let empty = Bounds(left: 0, top: 0, right: 0, bottom: 0)
}

/// One run of text on screen, with where it sits.
///
/// On Android this is produced either by the AccessibilityService (which fills
/// `viewId` and leaves `confidence` at 1.0) or by OCR (no `viewId`, a real
/// `confidence`). On iOS only the OCR shape is reachable — see
/// `docs/ios-platform-limits.md` — but the field stays so the two codebases
/// keep the same type and recorded fixtures stay interchangeable between them.
public struct TextBlock: Equatable, Hashable, Sendable, Codable {
    public let text: String
    public let bounds: Bounds
    public let viewId: String?
    public let confidence: Float

    public init(
        text: String,
        bounds: Bounds = .empty,
        viewId: String? = nil,
        confidence: Float = 1
    ) {
        self.text = text
        self.bounds = bounds
        self.viewId = viewId
        self.confidence = confidence
    }

    /// Rough proxy for font size. Neither the accessibility tree nor Vision
    /// reports text size, but a taller run almost always means bigger type —
    /// which is how we tell the headline fare from the small print.
    public var glyphHeight: Int { bounds.height }
}

/// One reading of the screen, from any source.
///
/// `flatText` and `inReadingOrder` are computed once in `init` and stored.
/// Kotlin gets this from `by lazy`; Swift structs cannot lazily memoise
/// without becoming mutating, and every parser touches both properties more
/// than once, so eager computation keeps the cost identical to Android's.
public struct ScreenSnapshot: Equatable, Sendable {
    public let packageName: String
    public let blocks: [TextBlock]
    public let capturedAtMs: Int64

    /// All text joined in reading order — handy for logging and regex fallbacks.
    public let flatText: String

    /// Blocks sorted top-to-bottom, then left-to-right. Reading order.
    public let inReadingOrder: [TextBlock]

    public init(packageName: String, blocks: [TextBlock], capturedAtMs: Int64 = 0) {
        self.packageName = packageName
        self.blocks = blocks
        self.capturedAtMs = capturedAtMs
        self.flatText = blocks.map(\.text).joined(separator: "\n")

        // Kotlin's `sortedWith` is a stable sort and the leg-assignment
        // heuristic depends on it: two blocks on the same baseline must keep
        // the order the source emitted them in. Swift's `sorted` gives no such
        // guarantee, so we break ties on the original index by hand.
        self.inReadingOrder = blocks.enumerated()
            .sorted { a, b in
                if a.element.bounds.top != b.element.bounds.top {
                    return a.element.bounds.top < b.element.bounds.top
                }
                if a.element.bounds.left != b.element.bounds.left {
                    return a.element.bounds.left < b.element.bounds.left
                }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    public var isEmpty: Bool {
        !blocks.contains { !$0.text.allSatisfy(\.isWhitespace) && !$0.text.isEmpty }
    }
}

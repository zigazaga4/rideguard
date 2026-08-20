import Foundation
import RideGuardCore

//  iOS's honest answer to Android's screen reading.
//
//  iOS cannot read another app's window and cannot draw over one — see
//  `docs/ios-platform-limits.md` for the API-by-API reasoning. What it CAN do
//  is accept a screenshot the driver shares into us and run on-device OCR over
//  it. The output is a `[TextBlock]`, which is precisely what the Android
//  AccessibilityService produces, so from `TokenScanner` downwards the two
//  apps run the same code on the same shape of data.
//
//  Deliberately NOT part of RideGuardCore: Core is Foundation-only so
//  `swift test` runs the whole domain suite on any machine, Linux included.
//  Vision would drag the entire domain onto an Apple platform.

#if canImport(Vision)

import Vision
import CoreGraphics

/// On-device text recognition over a screenshot.
///
/// Nothing leaves the phone: `VNRecognizeTextRequest` runs locally, and this
/// app has no networking code at all. That is a feature worth keeping — a
/// driver's offer screenshots contain passenger pickup addresses.
public struct VisionTextReader {

    public struct Options: Sendable {
        /// Preferred languages, best first. Filtered against what the installed
        /// Vision revision actually supports before use — Romanian is not
        /// available on every OS version, and passing an unsupported language
        /// makes the request fail outright rather than degrade.
        public var preferredLanguages: [String]
        /// Off, deliberately. Language correction is a spell-checker: it
        /// rewrites `17,50` to `17.50` or `1750`, and "0,8 km" to "0.8 km",
        /// which is the exact thing this app must not get wrong. Offer cards
        /// are numbers and place names, not prose, so correction has nothing
        /// to contribute and a lot to break.
        public var usesLanguageCorrection: Bool
        /// `.accurate` — a screenshot is a still image with a generous time
        /// budget, and `.fast` visibly drops decimal separators.
        public var recognitionLevel: VNRequestTextRecognitionLevel
        /// Fraction of image height. 0 means Vision's default (1/32), which
        /// picks up the small print under the fare.
        public var minimumTextHeight: Float

        public init(
            preferredLanguages: [String] = ["ro-RO", "en-US"],
            usesLanguageCorrection: Bool = false,
            recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
            minimumTextHeight: Float = 0
        ) {
            self.preferredLanguages = preferredLanguages
            self.usesLanguageCorrection = usesLanguageCorrection
            self.recognitionLevel = recognitionLevel
            self.minimumTextHeight = minimumTextHeight
        }
    }

    public enum ReadError: Error, LocalizedError {
        case notAnImage
        case recognitionFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .notAnImage:
                return "That attachment is not an image RideGuard can read."
            case .recognitionFailed(let underlying):
                return "Text recognition failed: \(underlying.localizedDescription)"
            }
        }
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Recognised lines, in Vision's order. One observation per text line maps
    /// one-to-one onto a `TextBlock`, which is the same granularity the Android
    /// accessibility tree gives us.
    public func readBlocks(from cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> [TextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.recognitionLevel
        request.usesLanguageCorrection = options.usesLanguageCorrection
        request.minimumTextHeight = options.minimumTextHeight
        request.recognitionLanguages = Self.resolveLanguages(options.preferredLanguages, for: request)

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ReadError.recognitionFailed(error)
        }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextBlock(
                text: candidate.string,
                bounds: Self.bounds(of: observation, imageWidth: width, imageHeight: height),
                viewId: nil,
                confidence: candidate.confidence
            )
        }
    }

    /// A snapshot in exactly the shape the Android capture layer produces, so
    /// the parsers cannot tell the two apart.
    public func snapshot(
        from cgImage: CGImage,
        packageName: String,
        orientation: CGImagePropertyOrientation = .up,
        capturedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) throws -> ScreenSnapshot {
        ScreenSnapshot(
            packageName: packageName,
            blocks: try readBlocks(from: cgImage, orientation: orientation),
            capturedAtMs: capturedAtMs
        )
    }

    /// Vision's normalised box has its origin at the BOTTOM-left; `Bounds` —
    /// like the Android tree it mirrors — measures from the TOP-left. Getting
    /// this flip wrong silently inverts reading order, which would swap the
    /// pickup and trip legs and quietly invert the verdict.
    private static func bounds(
        of observation: VNRecognizedTextObservation,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> Bounds {
        let rect = VNImageRectForNormalizedRect(observation.boundingBox, Int(imageWidth), Int(imageHeight))
        return Bounds(
            left: Int(rect.minX.rounded()),
            top: Int((imageHeight - rect.maxY).rounded()),
            right: Int(rect.maxX.rounded()),
            bottom: Int((imageHeight - rect.minY).rounded())
        )
    }

    /// Asking for a language the installed revision does not support throws at
    /// `perform` time, so we intersect first and always leave English in as a
    /// floor. Romanian offer cards are mostly digits and place names anyway;
    /// the English recogniser reads `17,50 lei` perfectly well.
    private static func resolveLanguages(_ preferred: [String], for request: VNRecognizeTextRequest) -> [String] {
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        guard !supported.isEmpty else { return ["en-US"] }
        var resolved = preferred.filter { supported.contains($0) }
        if !resolved.contains("en-US"), supported.contains("en-US") { resolved.append("en-US") }
        return resolved.isEmpty ? [supported[0]] : resolved
    }
}

#if canImport(ImageIO)
import ImageIO

extension VisionTextReader {
    /// A screenshot is ~3 MP and needs no downscaling, but a driver
    /// photographing a colleague's screen hands us a 12 MP frame, and a share
    /// extension is killed at around 120 MB of footprint. 4096 px on the long
    /// edge is far above what Vision needs to read a fare and well inside the
    /// budget.
    public static let maxPixelSize = 4096

    /// Decodes image data without touching UIKit, so the same code runs in the
    /// share extension (tight memory limits, no window) and in the app.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` rather than the full-size decode:
    /// it caps memory in one step and — with `WithTransform` — bakes in the
    /// EXIF orientation, so callers can keep passing `.up` and a photo taken
    /// in landscape still reads right way up.
    public static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ReadError.notAnImage
        }
        return try decode(source: source)
    }

    public static func decode(contentsOf url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ReadError.notAnImage
        }
        return try decode(source: source)
    }

    private static func decode(source: CGImageSource) throws -> CGImage {
        guard CGImageSourceGetCount(source) > 0 else { throw ReadError.notAnImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ReadError.notAnImage
        }
        return image
    }
}
#endif

/// Screenshot in, `RideOffer` out. The whole iOS capture story in one type.
public struct ScreenshotOfferReader {
    private let reader: VisionTextReader
    private let registry: OfferParserRegistry

    public init(
        reader: VisionTextReader = VisionTextReader(),
        registry: OfferParserRegistry = OfferParserRegistry()
    ) {
        self.reader = reader
        self.registry = registry
    }

    public struct Result: Sendable {
        public let platform: Platform
        public let offer: RideOffer?
        /// Kept so the UI can show "here is what I actually read" when the
        /// parse fails. A driver who can see the OCR output can tell whether
        /// to retake the screenshot or report a parser bug; a bare "couldn't
        /// read that" teaches them nothing.
        public let blocks: [TextBlock]

        public var recognizedText: String { blocks.map(\.text).joined(separator: "\n") }
    }

    public func read(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        fallbackPlatform: Platform,
        fareIsNet: (Platform) -> Bool
    ) throws -> Result {
        let blocks = try reader.readBlocks(from: cgImage, orientation: orientation)
        let text = blocks.map(\.text).joined(separator: "\n")
        let platform = ScreenshotPlatformGuess.guess(from: text, fallback: fallbackPlatform)

        // The synthesised package name is what routes to the right parser; it
        // is the one place iOS has to invent a value Android reads for free.
        let snapshot = ScreenSnapshot(
            packageName: platform.packageName,
            blocks: blocks,
            capturedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )

        let offer = registry.parse(snapshot, requireOfferKeywords: false, fareIsNet: fareIsNet)
        return Result(platform: platform, offer: offer, blocks: blocks)
    }
}

#endif

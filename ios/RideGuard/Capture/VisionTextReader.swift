import Foundation
import RideGuardCore

//  iOS's two ways of seeing a driver app's screen, sharing one Vision setup.
//
//  There are exactly two: a screenshot the driver shares into us (the share
//  extension), and a ReplayKit broadcast the driver starts from Control Centre
//  (`RideGuardBroadcast`). Both end up here, and both must read the same card
//  the same way — two copies of the Vision configuration is how the live HUD
//  and the after-the-fact card would quietly start disagreeing about the same
//  offer. See `docs/ios-platform-limits.md` for why there is no third way.
//
//  The output is a `[TextBlock]`, which is precisely what the Android
//  AccessibilityService produces, so from `TokenScanner` downwards the two
//  apps run the same code on the same shape of data.
//
//  Deliberately NOT part of RideGuardCore: Core is Foundation-only so
//  `swift test` runs the whole domain suite on any machine, Linux included.
//  Vision would drag the entire domain onto an Apple platform.

#if canImport(Vision)

import Vision
import CoreGraphics
import CoreVideo
// For `CGImagePropertyOrientation`, which lives in ImageIO and only reaches
// here by re-export otherwise. Whether that re-export happens depends on the
// SDK, and losing it is a confusing "cannot find type in scope".
import ImageIO

/// On-device text recognition over a screen image.
///
/// Nothing leaves the phone: `VNRecognizeTextRequest` runs locally, and this
/// app has no networking code at all. That is a feature worth keeping — a
/// driver's offer screen contains passenger pickup addresses.
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
        /// `.accurate`. `.fast` visibly drops decimal separators, and a fare
        /// read as `1750` instead of `17,50` is a hundredfold error presented
        /// with total confidence. It is the most expensive setting in this file
        /// and the least negotiable.
        public var recognitionLevel: VNRequestTextRecognitionLevel
        /// Fraction of IMAGE height, not of screen height — which is why it has
        /// to be set per call site rather than left alone.
        ///
        /// Vision's own default is 1/32. On a full-height screenshot that is
        /// ~56 px, which throws away the leg lines (`2,4 km · 5 min`) and the
        /// net disclaimer and keeps only the headline fare — a parse with a
        /// fare and no distance, which `HeuristicOfferParser` rejects outright.
        /// So it is always given a real value, low enough to keep the small
        /// print and high enough that Vision does not scan for sub-pixel noise.
        public var minimumTextHeight: Float

        public init(
            preferredLanguages: [String] = ["ro-RO", "en-US"],
            usesLanguageCorrection: Bool = false,
            recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
            minimumTextHeight: Float = 0.008
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

    // MARK: - Coordinates

    /// Where the image Vision actually looked at sits inside the screen it came
    /// from, measured in ORIGINAL screen pixels.
    ///
    /// This is the whole answer to the coordinate problem. Vision reports boxes
    /// normalised 0..1 against whatever image it was handed, origin at the
    /// BOTTOM-left. `Bounds` — and every reading-order and largest-text
    /// heuristic above it — is top-left origin in pixels of the ORIGINAL
    /// screen.
    ///
    /// Because the boxes are normalised, the downscale factor drops out
    /// entirely: multiplying by the size of the region as it was BEFORE
    /// scaling gives screen pixels directly. That is what keeps
    /// `TextBlock.glyphHeight` a usable proxy for font size instead of a number
    /// that shrinks when the frame is downscaled or grows on a denser phone —
    /// and `pickFare` picks the headline fare purely on glyph height.
    public struct BoundsProjection: Sendable {
        /// Size of the region handed to Vision, in original screen pixels —
        /// NOT the size of the (downscaled) buffer Vision actually saw.
        public let regionSize: CGSize
        /// Offset of that region's top-left corner from the SCREEN's top-left
        /// corner, in original screen pixels. Non-zero whenever the frame was
        /// cropped before recognition.
        public let regionOrigin: CGPoint

        public init(regionSize: CGSize, regionOrigin: CGPoint = .zero) {
            self.regionSize = regionSize
            self.regionOrigin = regionOrigin
        }

        public static func wholeImage(width: Int, height: Int) -> BoundsProjection {
            BoundsProjection(regionSize: CGSize(width: width, height: height))
        }

        /// The Y flip, and the single most dangerous line in the capture layer.
        ///
        /// `rect` is bottom-left origin within the region, so the distance from
        /// the region's TOP edge is `regionSize.height - rect.maxY`; adding
        /// `regionOrigin.y` puts it back on the screen. Invert this and reading
        /// order comes out upside down, which swaps the pickup leg with the
        /// paid leg — and a 2 km pickup for a 20 km ride becomes a 20 km pickup
        /// for a 2 km ride. Nothing crashes; the verdict is simply wrong.
        public func bounds(of normalizedBox: CGRect) -> Bounds {
            let rect = VNImageRectForNormalizedRect(
                normalizedBox,
                Int(regionSize.width),
                Int(regionSize.height)
            )
            return Bounds(
                left: Int((regionOrigin.x + rect.minX).rounded()),
                top: Int((regionOrigin.y + regionSize.height - rect.maxY).rounded()),
                right: Int((regionOrigin.x + rect.maxX).rounded()),
                bottom: Int((regionOrigin.y + regionSize.height - rect.minY).rounded())
            )
        }
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - Request

    /// Builds the one text request this app uses.
    ///
    /// Static, and public, so the broadcast extension can build it ONCE and
    /// re-perform it every frame. That matters: constructing a
    /// `VNRecognizeTextRequest` per frame reloads the recognition model, which
    /// a 50 MB extension running three frames a second cannot afford. Reusing
    /// one request is safe as long as it is never performed concurrently with
    /// itself — the results property is overwritten by each pass.
    public static func makeRequest(options: Options = Options()) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()

        // Pinned, and set FIRST — `supportedRecognitionLanguages()` below is
        // answered per revision, so resolving languages against an unpinned
        // request asks a question whose answer changes with the OS.
        //
        // Left unset, Vision uses whatever revision the running system defaults
        // to. That means an iOS update can silently change how the offer card
        // is tokenised, mid-shift, on a phone we cannot attach a debugger to —
        // and the symptom would be a parser that quietly stopped finding the
        // fare, with nothing in the diff to explain it. Revision 3 is the iOS
        // 16 baseline, which is this app's floor, so every supported device
        // reads the card the same way.
        request.revision = VNRecognizeTextRequestRevision3

        request.recognitionLevel = options.recognitionLevel
        request.usesLanguageCorrection = options.usesLanguageCorrection
        request.minimumTextHeight = options.minimumTextHeight
        request.recognitionLanguages = resolveLanguages(options.preferredLanguages, for: request)
        return request
    }

    /// One observation per text line maps one-to-one onto a `TextBlock`, which
    /// is the same granularity the Android accessibility tree gives us.
    public static func blocks(
        from results: [VNObservation]?,
        projection: BoundsProjection
    ) -> [TextBlock] {
        let observations = (results as? [VNRecognizedTextObservation]) ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextBlock(
                text: candidate.string,
                bounds: projection.bounds(of: observation.boundingBox),
                viewId: nil,
                confidence: candidate.confidence
            )
        }
    }

    // MARK: - Still images (share extension)

    public func readBlocks(
        from cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) throws -> [TextBlock] {
        let request = Self.makeRequest(options: options)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ReadError.recognitionFailed(error)
        }
        return Self.blocks(
            from: request.results,
            projection: .wholeImage(width: cgImage.width, height: cgImage.height)
        )
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

    // MARK: - Live frames (broadcast extension)

    /// Recognises text straight out of a pixel buffer.
    ///
    /// No `CGImage` in the middle on purpose: `VNImageRequestHandler` takes a
    /// `CVPixelBuffer` directly, and going via `CGImage`/`UIImage` would copy
    /// the whole frame into a second allocation, three times a second, inside
    /// a process with a 50 MB ceiling.
    ///
    /// `projection` describes where `pixelBuffer` sits inside the original
    /// screen, because by the time a frame reaches here it has usually been
    /// cropped and downscaled — and the parser needs original screen pixels.
    ///
    /// `request` is passed in rather than built here so the caller can keep one
    /// warm across frames.
    public static func readBlocks(
        from pixelBuffer: CVPixelBuffer,
        request: VNRecognizeTextRequest,
        projection: BoundsProjection,
        orientation: CGImagePropertyOrientation = .up
    ) throws -> [TextBlock] {
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            throw ReadError.recognitionFailed(error)
        }
        return blocks(from: request.results, projection: projection)
    }

    // MARK: - Languages

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

/// Screenshot in, `RideOffer` out. The whole share-extension capture story in
/// one type. The live path does not use this: it needs the parsed offer and
/// the economics on separate steps so it can dedupe between them.
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

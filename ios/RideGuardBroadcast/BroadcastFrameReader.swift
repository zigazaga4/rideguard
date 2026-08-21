import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import RideGuardCore
import Vision

/// One screen frame in, `[TextBlock]` out, inside a 50 MB budget.
///
/// ## The budget is the design
///
/// A Broadcast Upload Extension is killed at roughly **50 MB** of footprint,
/// with no crash log worth reading — the broadcast simply ends mid-shift. Every
/// decision in this file is a consequence:
///
///  - **Crop before anything else.** The offer card lives in the bottom of the
///    screen; the top is a map, which is expensive to OCR and contains nothing
///    but street names that look like addresses to the parser.
///  - **Downscale to a fixed long edge.** Costs scale with pixel count, and an
///    iPhone 15 Pro Max frame is 2.4× the pixels of an iPhone 11's for exactly
///    the same card. Normalising the size makes the memory and latency of this
///    file device-independent, which is the only way to reason about the
///    budget at all.
///  - **One `CIContext`, one destination buffer, one `VNRecognizeTextRequest`,
///    for the whole broadcast.** Each of the three is expensive to build —
///    a `CIContext` compiles shaders, a request loads the recognition model —
///    and building them per frame is the difference between a flat footprint
///    and one that climbs until iOS kills us.
final class BroadcastFrameReader {

    // MARK: - Heuristics

    /// Fraction of the screen HEIGHT, measured up from the bottom, that Vision
    /// is allowed to look at.
    ///
    /// On both the Bolt and the Uber Romanian cards the sheet covers roughly
    /// the bottom half of the display and the rest is map. 0.60 keeps the whole
    /// card plus margin on the phones checked so far, and drops Bolt's `✕
    /// Refuză` pill, which floats on the map ABOVE the sheet — which is why the
    /// keyword gate in `LiveOfferPipeline` must not lean on "refuz".
    ///
    /// This is a guess until it has been checked against real screenshots from
    /// a real shift on a real phone, and the risk is not symmetric. Too
    /// generous only costs pixels. Too tight cuts off the headline fare, which
    /// sits at the TOP of the sheet — and `pickFare` then quietly settles on
    /// the largest money it can still see, which on a surge card is the bonus
    /// line. That is a wrong number delivered with full confidence, so err
    /// upward when tuning.
    static let offerCardHeightFraction: CGFloat = 0.60

    /// Long edge, in pixels, of the image Vision actually sees.
    ///
    /// The card's small print — the leg lines the parse cannot do without — is
    /// around 22 px on a 2x phone. After cropping to `offerCardHeightFraction`
    /// and scaling that region's long edge to 720, it lands near 15 px, which
    /// `.accurate` reads reliably and which sits comfortably above
    /// `minimumTextHeight` below. Going lower starts eating decimal separators;
    /// going higher costs memory quadratically. If digits come back mangled on
    /// real captures, raise this to ~900 before touching anything else.
    static let recognitionLongEdge: CGFloat = 720

    /// `minimumTextHeight` is a fraction of the RECOGNISED image's height. At a
    /// 720 px long edge, 0.015 is about 11 px — below the small print, above
    /// the anti-aliasing fuzz of map labels bleeding in at the crop line.
    /// Leaving Vision's own 1/32 default would put the floor at 22 px and throw
    /// the leg lines away, and a card with a fare and no distance is rejected
    /// outright by the parser.
    private static let visionOptions = VisionTextReader.Options(
        preferredLanguages: ["ro-RO", "en-US"],
        usesLanguageCorrection: false,
        recognitionLevel: .accurate,
        minimumTextHeight: 0.015
    )

    // MARK: - Reused state

    /// `.cacheIntermediates: false` is the load-bearing option: without it Core
    /// Image holds onto intermediate textures between renders, and the
    /// footprint climbs frame over frame until the extension is killed.
    /// `.workingColorSpace: NSNull()` turns off colour management, which we do
    /// not need — OCR reads shapes, not colours — and which is pure cost.
    private let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .cacheIntermediates: false,
        .name: "RideGuardBroadcast",
    ])

    private lazy var request = VisionTextReader.makeRequest(
        options: BroadcastFrameReader.visionOptions
    )

    private var destination: CVPixelBuffer?
    private var destinationWidth = 0
    private var destinationHeight = 0

    // MARK: - Reading

    /// Returns nil when the frame could not be turned into an image at all.
    /// Callers treat that the same as "no offer on screen": if we cannot see,
    /// we must not keep a verdict on the driver's display.
    func readBlocks(
        from pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> [TextBlock]? {
        guard let prepared = prepare(pixelBuffer, orientation: orientation) else { return nil }
        return try? VisionTextReader.readBlocks(
            from: prepared.buffer,
            request: request,
            projection: prepared.projection,
            // The frame was already straightened by `prepare`, so Vision must
            // not rotate it a second time.
            orientation: .up
        )
    }

    /// Drops the reused buffers. Called when the broadcast ends, so a paused
    /// extension is not sitting on a couple of megabytes it cannot use.
    func releaseResources() {
        destination = nil
        destinationWidth = 0
        destinationHeight = 0
    }

    // MARK: - Crop, straighten, downscale

    private struct PreparedFrame {
        let buffer: CVPixelBuffer
        let projection: VisionTextReader.BoundsProjection
    }

    /// Straightens the frame, crops it to the card region, scales it down, and
    /// renders the result into the one buffer we keep around.
    ///
    /// The crop is done here rather than via `VNImageBasedRequest.regionOfInterest`
    /// on purpose. An ROI leaves it ambiguous whether the observations come
    /// back normalised against the region or against the full image, and
    /// getting that wrong misplaces every block vertically — exactly the
    /// silent leg-swapping failure `BoundsProjection` exists to prevent.
    /// Cropping in the render we have to do anyway makes the geometry
    /// arithmetic, not a question about Vision's internals, and hands Vision
    /// fewer pixels besides.
    private func prepare(
        _ pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> PreparedFrame? {
        // `CIImage` retains the frame until it is released. Everything here is
        // synchronous and inside the caller's autoreleasepool, so ReplayKit
        // gets its buffer back before the next one arrives; holding one across
        // an async hop would starve its pool and stall the broadcast.
        var image = CIImage(cvPixelBuffer: pixelBuffer)

        // ReplayKit hands the frame in the capture device's native orientation
        // and describes the display orientation separately, so a rotated phone
        // arrives sideways. Straighten first or "the bottom of the screen"
        // means the wrong edge.
        if orientation != .up {
            image = image.oriented(orientation)
        }
        if image.extent.origin != .zero {
            image = image.transformed(
                by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y)
            )
        }

        let screenWidth = image.extent.width
        let screenHeight = image.extent.height
        guard screenWidth > 0, screenHeight > 0 else { return nil }

        // Core Image's origin is bottom-left, so the bottom of the DISPLAY is
        // y ∈ [0, cropHeight) — no flip needed at this step. The flip happens
        // once, in `BoundsProjection`, and only there.
        let cropHeight = (screenHeight * Self.offerCardHeightFraction).rounded()
        guard cropHeight > 0 else { return nil }
        let cropped = image.cropped(to: CGRect(x: 0, y: 0, width: screenWidth, height: cropHeight))

        // Never upscale: a small screen gains no legibility from it and pays
        // the full memory cost.
        let scale = min(1, Self.recognitionLongEdge / max(screenWidth, cropHeight))
        let scaled = scale < 1 ? cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : cropped

        // Round DOWN so the render bounds can never exceed the scaled extent.
        let outputWidth = Int((screenWidth * scale).rounded(.down))
        let outputHeight = Int((cropHeight * scale).rounded(.down))
        guard outputWidth > 0, outputHeight > 0,
              let buffer = destinationBuffer(width: outputWidth, height: outputHeight)
        else { return nil }

        // nil colour space to match `.workingColorSpace: NSNull()` above —
        // asking for a conversion the context is not managing is wasted work.
        context.render(
            scaled,
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
            colorSpace: nil
        )

        return PreparedFrame(
            buffer: buffer,
            projection: VisionTextReader.BoundsProjection(
                // ORIGINAL pixels, before the downscale: this is what puts
                // glyph heights back on the screen's scale.
                regionSize: CGSize(width: screenWidth, height: cropHeight),
                // The crop was taken from the bottom, so its top edge sits this
                // far down the screen.
                regionOrigin: CGPoint(x: 0, y: screenHeight - cropHeight)
            )
        )
    }

    /// One buffer, reused for every frame of the broadcast. Rebuilt only when
    /// the geometry actually changes, which in practice means the driver
    /// rotated the phone.
    private func destinationBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if let existing = destination, destinationWidth == width, destinationHeight == height {
            return existing
        }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            // IOSurface-backed, so Core Image renders on the GPU and Vision
            // reads the same memory. Without it both sides fall back to CPU
            // copies of the whole frame.
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]

        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &created
        )
        guard status == kCVReturnSuccess, let created else { return nil }

        destination = created
        destinationWidth = width
        destinationHeight = height
        return created
    }
}

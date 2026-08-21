import AVFoundation
import CoreText
import UIKit
import RideGuardCore

/// One frame's worth of HUD, with every number already formatted.
///
/// Formatting happens here, off the render loop's hot path and off the main
/// thread, so that drawing a frame is nothing but glyph layout and fills. It is
/// also what makes "did anything actually change?" a cheap `==`.
struct HudSnapshot: Equatable {
    /// Big, bold, verdict-coloured. What the ride pays per kilometre driven.
    var headline: String
    /// The same figure after fuel — what he keeps.
    var netPerKm: String
    /// Quiet context: distance, hourly.
    var context: String
    /// Only ever set when there is genuinely something to warn about.
    var badge: String?
    var accent: UIColor
    var netIsNegative: Bool
    /// UNKNOWN means the card could not be read. Dimming is the honest signal;
    /// a crisp number the driver would trust and act on is not.
    var dimmed: Bool
    var isWaiting: Bool

    /// Shown when there is no offer on screen, and when nothing has arrived for
    /// long enough that the last verdict can no longer be trusted.
    ///
    /// Android hides its overlay outright at this point. iOS cannot: dismissing
    /// the PiP window is a one-way door that only the driver can reopen, and he
    /// is driving. So the window stays and says nothing — which is the same
    /// promise, kept differently.
    static let waiting = HudSnapshot(
        headline: "",
        netPerKm: "",
        context: "",
        badge: nil,
        accent: HudColors.unknown,
        netIsNegative: false,
        dimmed: true,
        isWaiting: true
    )

    init(
        headline: String,
        netPerKm: String,
        context: String,
        badge: String?,
        accent: UIColor,
        netIsNegative: Bool,
        dimmed: Bool,
        isWaiting: Bool
    ) {
        self.headline = headline
        self.netPerKm = netPerKm
        self.context = context
        self.badge = badge
        self.accent = accent
        self.netIsNegative = netIsNegative
        self.dimmed = dimmed
        self.isWaiting = isWaiting
    }

    init(verdict: LiveVerdict) {
        var context = "\(NumberParsing.formatRate(verdict.totalKm, decimals: 1)) km"
        if let perHour = verdict.netPerHour {
            context += "  ·  \(NumberParsing.formatAuto(perHour)) \(verdict.currency)/h"
        }

        // Only above the threshold, and only then. A badge that is always on
        // screen stops being a warning and becomes decoration.
        var badge: String?
        if let ratio = verdict.deadheadRatio, ratio > 0.8 {
            badge = "↩ \(NumberParsing.formatRate(ratio, decimals: 1))×"
        }

        self.init(
            headline: NumberParsing.formatFixed(verdict.earningsPerKm),
            netPerKm: NumberParsing.formatFixed(verdict.netPerKm),
            context: context,
            badge: badge,
            accent: HudColors.forVerdict(verdict.verdict),
            netIsNegative: verdict.netPerKm < 0,
            dimmed: verdict.verdict.uppercased() == "UNKNOWN",
            isWaiting: false
        )
    }
}

/// Draws `HudSnapshot`s into `CMSampleBuffer`s for the PiP display layer.
///
/// Not thread-safe and not meant to be: one instance is owned by
/// `PiPOverlayController`'s render queue and touched from nowhere else. The
/// pixel buffer pool and the format description are created once and reused for
/// the whole shift — allocating a fresh buffer twice a second for eight hours is
/// exactly how this app gets killed for memory instead of failing loudly.
final class HudRenderer {

    /// 480 × 270.
    ///
    /// 16:9 because a PiP window is a video window and the system is best
    /// behaved with an ordinary video aspect ratio; unusual ones get letterboxed
    /// or clamped and the layout silently loses its edges. 480 px wide is close
    /// to 1:1 with the pixels the window actually gets — the largest PiP window
    /// on an iPhone 11 is roughly 230 pt, so about 460 px — which means the text
    /// is never upscaled, and a full redraw still costs well under a millisecond.
    static let renderSize = CGSize(width: 480, height: 270)

    private let size = HudRenderer.renderSize
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private var pool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private var lastPresentationTime: CMTime = .invalid

    // Layout, in render-space pixels. Proportions are Android's — 30sp / 17sp /
    // 11sp — scaled up to this canvas, so the hierarchy the driver has learned
    // survives the port.
    private let stripWidth: CGFloat = 10
    private let inset = UIEdgeInsets(top: 18, left: 24, bottom: 18, right: 22)
    private let headlineSize: CGFloat = 84
    private let netSize: CGFloat = 48
    private let contextSize: CGFloat = 30

    // MARK: - Frames

    /// Nil means this frame could not be produced. The caller must not treat
    /// that as fatal: PiP only needs the *stream* to continue, and one skipped
    /// frame out of two per second is invisible.
    func makeSampleBuffer(_ snapshot: HudSnapshot, duration: CMTime) -> CMSampleBuffer? {
        guard let pixelBuffer = makePixelBuffer() else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: colorSpace,
                // Premultiplied-first plus little-endian is BGRA in memory,
                // which is what the pixel buffer is and what the display layer
                // wants. Any other combination costs a conversion per frame.
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        draw(snapshot, in: context)

        return wrap(pixelBuffer, duration: duration)
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        if pool == nil { pool = makePool() }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    private func makePool() -> CVPixelBufferPool? {
        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            // IOSurface backing is not optional here. Without it the buffer
            // cannot be handed to the video pipeline and the display layer
            // quietly shows nothing at all.
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        // Three is the whole working set: one being drawn, one in flight to the
        // layer, one the layer is still displaying.
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]

        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelAttributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess else { return nil }
        return pool
    }

    private func wrap(_ pixelBuffer: CVPixelBuffer, duration: CMTime) -> CMSampleBuffer? {
        if formatDescription == nil
            || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            var created: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &created
            ) == noErr else { return nil }
            formatDescription = created
        }
        guard let formatDescription else { return nil }

        // Host-clock time stamps: the display layer has no control timebase, so
        // these only have to be valid and strictly increasing. They are not,
        // however, optional — a sample buffer with invalid timing is rejected
        // outright and the HUD never appears.
        var presentation = CMClockGetTime(CMClockGetHostTimeClock())
        if lastPresentationTime.isValid, presentation <= lastPresentationTime {
            presentation = lastPresentationTime + CMTime(value: 1, timescale: 1000)
        }
        lastPresentationTime = presentation

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentation,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        markDisplayImmediately(sampleBuffer)
        return sampleBuffer
    }

    /// Without this the layer holds frames back waiting for a timebase we never
    /// set, and the HUD shows one frame and then freezes.
    private func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    // MARK: - Drawing

    private func draw(_ snapshot: HudSnapshot, in ctx: CGContext) {
        let bounds = CGRect(origin: .zero, size: size)

        // Buffers come back from the pool with the previous frame still in them.
        // Painting the full rect every time is what stops the last ride's number
        // bleeding through the "waiting" frame.
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(bounds)
        ctx.setFillColor(HudColors.surface.cgColor)
        ctx.fill(bounds)

        // Core Graphics puts the origin at the bottom left; every layout number
        // below is measured from the top, like the Compose original. The text
        // matrix has to be flipped back or the glyphs come out upside down.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        // Everything except the card itself fades when the parse was too poor to
        // trust, matching the Android `.alpha(0.75)`.
        if snapshot.dimmed { ctx.setAlpha(0.75) }

        // The verdict strip: the part that is readable from the corner of an eye.
        ctx.setFillColor(snapshot.accent.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: stripWidth, height: size.height))

        let content = CGRect(
            x: stripWidth + inset.left,
            y: inset.top,
            width: size.width - stripWidth - inset.left - inset.right,
            height: size.height - inset.top - inset.bottom
        )

        if snapshot.isWaiting {
            drawWaiting(in: ctx, content: content)
        } else {
            drawVerdict(snapshot, in: ctx, content: content)
        }
    }

    private func drawVerdict(_ snapshot: HudSnapshot, in ctx: CGContext, content: CGRect) {
        let badge = snapshot.badge.map {
            makeLine($0, size: contextSize * 0.95, weight: .bold, color: HudColors.bad)
        }
        let badgeWidth = badge.map { $0.width + 16 + 12 } ?? 0

        let headlineGap: CGFloat = 6
        var headline = makeLine(
            snapshot.headline, size: headlineSize, weight: .black,
            color: snapshot.accent, monospacedDigits: true
        )
        var suffix = makeLine("/km", size: headlineSize * 0.42, weight: .bold, color: HudColors.secondary)

        // A loss-making offer is the one case wide enough to overflow
        // ("-12.50 /km"), and it is precisely the number that must not be
        // clipped. Shrink the headline rather than let it run under the badge.
        let headlineRoom = content.width - badgeWidth - suffix.width - headlineGap
        if headline.width > headlineRoom, headline.width > 0 {
            let scale = max(0.6, headlineRoom / headline.width)
            headline = makeLine(
                snapshot.headline, size: headlineSize * scale, weight: .black,
                color: snapshot.accent, monospacedDigits: true
            )
            suffix = makeLine(
                "/km", size: headlineSize * scale * 0.42, weight: .bold, color: HudColors.secondary
            )
        }

        let arrow = makeLine("↓", size: netSize * 0.6, weight: .regular, color: HudColors.secondary)
        let net = makeLine(
            snapshot.netPerKm, size: netSize, weight: .bold,
            color: snapshot.netIsNegative ? HudColors.bad : HudColors.primary,
            monospacedDigits: true
        )
        let netLabel = makeLine(
            "/km after fuel", size: netSize * 0.58, weight: .medium, color: HudColors.secondary
        )
        let contextLine = makeLine(
            snapshot.context, size: contextSize, weight: .medium,
            color: HudColors.secondary, maxWidth: content.width
        )

        // Rows are stacked from measured metrics rather than guessed line
        // heights, then centred as a block: whatever the system font does with
        // ascenders at these sizes, nothing clips and nothing drifts.
        let gapUnderHeadline: CGFloat = 4
        let gapUnderNet: CGFloat = 8
        let headlineRow = headline.height
        let netRow = max(net.height, netLabel.height)
        let contextRow = contextLine.height
        let total = headlineRow + gapUnderHeadline + netRow + gapUnderNet + contextRow

        var y = content.minY + max(0, (content.height - total) / 2)

        let headlineBaseline = y + headline.ascent
        headline.draw(in: ctx, x: content.minX, baseline: headlineBaseline)
        suffix.draw(in: ctx, x: content.minX + headline.width + headlineGap, baseline: headlineBaseline)
        if let badge {
            drawBadge(badge, in: ctx, rightEdge: content.maxX, centerY: y + headlineRow / 2)
        }

        y += headlineRow + gapUnderHeadline
        let netBaseline = y + max(net.ascent, netLabel.ascent)
        var x = content.minX
        arrow.draw(in: ctx, x: x, baseline: netBaseline)
        x += arrow.width + 6
        net.draw(in: ctx, x: x, baseline: netBaseline)
        x += net.width + 7
        netLabel.draw(in: ctx, x: x, baseline: netBaseline)

        y += netRow + gapUnderNet
        contextLine.draw(in: ctx, x: content.minX, baseline: y + contextLine.ascent)
    }

    private func drawWaiting(in ctx: CGContext, content: CGRect) {
        let title = makeLine("RideGuard", size: 36, weight: .semibold, color: HudColors.secondary)
        let body = makeLine(
            "watching for offers", size: 28, weight: .regular,
            color: HudColors.secondary.withAlphaComponent(0.65)
        )
        let gap: CGFloat = 6
        let total = title.height + gap + body.height
        let top = content.minY + max(0, (content.height - total) / 2)

        title.draw(in: ctx, x: content.minX, baseline: top + title.ascent)
        body.draw(in: ctx, x: content.minX, baseline: top + title.height + gap + body.ascent)
    }

    private func drawBadge(_ text: HudLine, in ctx: CGContext, rightEdge: CGFloat, centerY: CGFloat) {
        let padX: CGFloat = 8
        let padY: CGFloat = 4
        let rect = CGRect(
            x: rightEdge - text.width - padX * 2,
            y: centerY - (text.height + padY * 2) / 2,
            width: text.width + padX * 2,
            height: text.height + padY * 2
        )
        ctx.setFillColor(HudColors.bad.withAlphaComponent(0.18).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        text.draw(in: ctx, x: rect.minX + padX, baseline: rect.minY + padY + text.ascent)
    }

    private func makeLine(
        _ text: String,
        size: CGFloat,
        weight: UIFont.Weight,
        color: UIColor,
        monospacedDigits: Bool = false,
        maxWidth: CGFloat? = nil
    ) -> HudLine {
        let line = HudLine(text, font: font(size, weight, monospacedDigits), color: color)
        guard let maxWidth, line.width > maxWidth, line.width > 0 else { return line }
        let shrunk = size * max(0.55, maxWidth / line.width)
        return HudLine(text, font: font(shrunk, weight, monospacedDigits), color: color)
    }

    /// Monospaced digits on the two per-kilometre numbers, so a 4 replacing a 1
    /// does not shift the decimal point sideways between frames. A number that
    /// twitches every time it updates is hard to read at speed.
    private func font(_ size: CGFloat, _ weight: UIFont.Weight, _ monospacedDigits: Bool) -> UIFont {
        monospacedDigits
            ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
    }
}

/// A single laid-out line of text with its metrics.
///
/// Core Text rather than UIKit string drawing: this runs on a background queue
/// for hours, and `CTLine` is safe there with no ceremony.
private struct HudLine {
    private let line: CTLine
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    var height: CGFloat { ascent + descent }

    init(_ text: String, font: UIFont, color: UIColor) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            // Core Text's own colour key with a CGColor. `.foregroundColor` with
            // a UIColor is a UIKit convention Core Text is not obliged to
            // honour, and when it does not, the text draws black on a black card
            // — invisible, with nothing in the logs to explain it.
            kCTForegroundColorAttributeName as NSAttributedString.Key: color.cgColor,
        ])
        let created = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0

        line = created
        width = CGFloat(CTLineGetTypographicBounds(created, &ascent, &descent, &leading))
        self.ascent = ascent
        self.descent = descent
    }

    func draw(in ctx: CGContext, x: CGFloat, baseline: CGFloat) {
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
    }
}

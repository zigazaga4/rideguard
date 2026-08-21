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
    /// The verdict as a word — "Profitable", "Not profitable". Colour alone was
    /// the whole signal here until now, which asked a driver to remember what
    /// amber meant while merging into traffic, and told a colour-blind driver
    /// nothing at all.
    var status: String
    /// One line under the word saying what it is based on.
    var statusDetail: String
    /// Which driver app this offer came from. Already known; never used to be
    /// drawn, so two apps' offers looked identical on the HUD.
    var platform: String
    /// Big, bold, verdict-coloured. What the ride pays per kilometre driven.
    var headline: String
    /// What the headline number actually means, in words.
    var headlineCaption: String
    /// The same figure after fuel — what he keeps.
    var netPerKm: String
    /// What the net number actually means, in words.
    var netCaption: String
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
        status: "",
        statusDetail: "",
        platform: "",
        headline: "",
        headlineCaption: "",
        netPerKm: "",
        netCaption: "",
        context: "",
        badge: nil,
        accent: HudColors.unknown,
        netIsNegative: false,
        dimmed: true,
        isWaiting: true
    )

    init(
        status: String,
        statusDetail: String,
        platform: String,
        headline: String,
        headlineCaption: String,
        netPerKm: String,
        netCaption: String,
        context: String,
        badge: String?,
        accent: UIColor,
        netIsNegative: Bool,
        dimmed: Bool,
        isWaiting: Bool
    ) {
        self.status = status
        self.statusDetail = statusDetail
        self.platform = platform
        self.headline = headline
        self.headlineCaption = headlineCaption
        self.netPerKm = netPerKm
        self.netCaption = netCaption
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

        // The channel carries the verdict as a raw string. Round-tripping it
        // through the enum means the HUD, the verdict card and the Dynamic
        // Island cannot say different words about the same ride, and an
        // unrecognised value degrades to "can't read it" rather than to a
        // confident-looking blank.
        let decoded = Verdict(rawValue: verdict.verdict.uppercased()) ?? .unknown

        self.init(
            status: decoded.statusLabel,
            statusDetail: decoded.statusDetail,
            platform: verdict.platform.uppercased(),
            headline: NumberParsing.formatFixed(verdict.earningsPerKm),
            headlineCaption: "what the ride pays per km",
            netPerKm: NumberParsing.formatFixed(verdict.netPerKm),
            netCaption: "what you keep after fuel",
            context: context,
            badge: badge,
            accent: HudColors.forVerdict(verdict.verdict),
            netIsNegative: verdict.netPerKm < 0,
            dimmed: decoded == .unknown,
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

    /// 640 × 480 — 4:3.
    ///
    /// This was 480 × 270 (16:9) and the change is worth explaining, because it
    /// is the one number here that behaves counter-intuitively.
    ///
    /// **An app cannot set the size of its PiP window.** The system picks it and
    /// scales our buffer to fit (`videoGravity = .resizeAspect`), so raising the
    /// pixel count alone changes resolution and nothing else — the window does
    /// not grow. What the app *does* control is the aspect ratio, and the window
    /// is sized primarily by its width. A taller ratio therefore buys real
    /// on-screen height at the same width, and height is what "fit more in"
    /// actually needs: at 16:9 the old three rows already used 206 of 234
    /// usable px, so a fourth row did not fit at any resolution.
    ///
    /// 4:3 rather than something taller still, because the original constraint
    /// has not gone away: a PiP window is a video window, and the system is
    /// best behaved with an ordinary video ratio. 4:3 is the most ordinary
    /// non-widescreen ratio there is. Anything more unusual risks being
    /// letterboxed or clamped, which loses the layout's edges silently.
    ///
    /// 640 px wide keeps text at roughly 1:1 with the pixels the window gets
    /// (the largest PiP window on an iPhone 11 is ~230 pt ≈ 460 px), so glyphs
    /// are never upscaled and a full redraw still costs well under a
    /// millisecond. Reverting is a one-line change back to `480 × 270`; the
    /// rest of the layout is derived from this constant.
    static let renderSize = CGSize(width: 640, height: 480)

    private let size = HudRenderer.renderSize
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private var pool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private var lastPresentationTime: CMTime = .invalid

    // Layout, in render-space pixels. The hierarchy is Android's — one dominant
    // figure, one supporting figure, quiet context — with a verdict word above
    // it and a caption under each number saying what it means.
    private let stripWidth: CGFloat = 12
    private let inset = UIEdgeInsets(top: 20, left: 26, bottom: 20, right: 24)
    private let statusSize: CGFloat = 44
    private let headlineSize: CGFloat = 92
    private let netSize: CGFloat = 52
    private let captionSize: CGFloat = 25
    private let contextSize: CGFloat = 28

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
        let netSuffix = makeLine(
            "/km", size: netSize * 0.58, weight: .medium, color: HudColors.secondary
        )
        let contextLine = makeLine(
            snapshot.context, size: contextSize, weight: .medium,
            color: HudColors.secondary, maxWidth: content.width
        )

        // The verdict, in words. Drawn in the accent colour so it reinforces the
        // strip rather than competing with it, and uppercased for the same
        // reason the strip is 12 px wide: this is the line read first.
        let status = makeLine(
            snapshot.status.uppercased(), size: statusSize, weight: .heavy,
            color: snapshot.accent, maxWidth: content.width * 0.72
        )
        let platform = snapshot.platform.isEmpty ? nil : makeLine(
            snapshot.platform, size: captionSize, weight: .bold,
            color: HudColors.secondary
        )
        let statusDetail = makeLine(
            snapshot.statusDetail, size: captionSize, weight: .regular,
            color: HudColors.secondary, maxWidth: content.width
        )
        let headlineCaption = makeLine(
            snapshot.headlineCaption, size: captionSize, weight: .medium,
            color: HudColors.secondary, maxWidth: content.width
        )
        let netCaption = makeLine(
            snapshot.netCaption, size: captionSize, weight: .medium,
            color: HudColors.secondary, maxWidth: content.width
        )

        // Rows are stacked from measured metrics rather than guessed line
        // heights, then centred as a block: whatever the system font does with
        // ascenders at these sizes, nothing clips and nothing drifts.
        let gapUnderStatus: CGFloat = 2
        let gapUnderDetail: CGFloat = 14
        let gapUnderCaption: CGFloat = 12
        let gapUnderNumber: CGFloat = 2

        let statusRow = max(status.height, platform?.height ?? 0)
        let netRow = max(net.height, netSuffix.height)
        let total = statusRow + gapUnderStatus
            + statusDetail.height + gapUnderDetail
            + headline.height + gapUnderNumber
            + headlineCaption.height + gapUnderCaption
            + netRow + gapUnderNumber
            + netCaption.height + gapUnderCaption
            + contextLine.height

        var y = content.minY + max(0, (content.height - total) / 2)

        status.draw(in: ctx, x: content.minX, baseline: y + status.ascent)
        if let platform {
            // Right-aligned on the status row: it identifies the offer without
            // taking a row of its own.
            platform.draw(
                in: ctx,
                x: content.maxX - platform.width,
                baseline: y + status.ascent
            )
        }

        y += statusRow + gapUnderStatus
        statusDetail.draw(in: ctx, x: content.minX, baseline: y + statusDetail.ascent)

        y += statusDetail.height + gapUnderDetail
        let headlineBaseline = y + headline.ascent
        headline.draw(in: ctx, x: content.minX, baseline: headlineBaseline)
        suffix.draw(in: ctx, x: content.minX + headline.width + headlineGap, baseline: headlineBaseline)
        if let badge {
            drawBadge(badge, in: ctx, rightEdge: content.maxX, centerY: y + headline.height / 2)
        }

        y += headline.height + gapUnderNumber
        headlineCaption.draw(in: ctx, x: content.minX, baseline: y + headlineCaption.ascent)

        y += headlineCaption.height + gapUnderCaption
        let netBaseline = y + max(net.ascent, netSuffix.ascent)
        var x = content.minX
        arrow.draw(in: ctx, x: x, baseline: netBaseline)
        x += arrow.width + 6
        net.draw(in: ctx, x: x, baseline: netBaseline)
        x += net.width + 7
        netSuffix.draw(in: ctx, x: x, baseline: netBaseline)

        y += netRow + gapUnderNumber
        netCaption.draw(in: ctx, x: content.minX, baseline: y + netCaption.ascent)

        y += netCaption.height + gapUnderCaption
        contextLine.draw(in: ctx, x: content.minX, baseline: y + contextLine.ascent)
    }

    private func drawWaiting(in ctx: CGContext, content: CGRect) {
        let title = makeLine("RideGuard", size: 42, weight: .semibold, color: HudColors.secondary)
        let body = makeLine(
            "Watching for offers", size: captionSize + 3, weight: .regular,
            color: HudColors.secondary.withAlphaComponent(0.7),
            maxWidth: content.width
        )
        // Says plainly that the empty window is working, not broken. A driver
        // who sees a blank HUD mid-shift otherwise has no way to tell whether
        // the broadcast died, and stopping to check costs him the next offer.
        let hint = makeLine(
            "The next one will show up here", size: captionSize - 1, weight: .regular,
            color: HudColors.secondary.withAlphaComponent(0.5),
            maxWidth: content.width
        )
        let gap: CGFloat = 8
        let total = title.height + gap + body.height + 4 + hint.height
        var y = content.minY + max(0, (content.height - total) / 2)

        title.draw(in: ctx, x: content.minX, baseline: y + title.ascent)
        y += title.height + gap
        body.draw(in: ctx, x: content.minX, baseline: y + body.ascent)
        y += body.height + 4
        hint.draw(in: ctx, x: content.minX, baseline: y + hint.ascent)
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

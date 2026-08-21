import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ReplayKit

/// The one place on iOS that sees another app's pixels.
///
/// ReplayKit hands system-wide screen frames to a Broadcast Upload Extension
/// and to nothing else. It also refuses to let that extension draw anything, so
/// this process reads and computes and then posts the answer across the App
/// Group for the app to display — see `Core/Live/LiveVerdict.swift` for why the
/// split is not a choice.
///
/// ## What will kill this, and what stops it
///
/// The extension is terminated at roughly **50 MB** of footprint, silently, in
/// the middle of a shift. Frames arrive at up to 60 a second; an offer card is
/// static for its whole fifteen-second life, so all but two or three of those
/// per second are pure cost. The throttle below is the single most important
/// line in the file, and the `autoreleasepool` around each processed frame is
/// the second — Vision allocates heavily, and without an explicit drain the
/// peaks stack up across frames until one of them is the last.
final class SampleHandler: RPBroadcastSampleHandler {

    /// Three frames a second.
    ///
    /// The card lives for ~15 s, so anything above about 2 fps is already fast
    /// enough that the driver sees the verdict as the card appears. The ceiling
    /// is the A13 in an iPhone 11: `.accurate` recognition over a cropped,
    /// downscaled frame is well inside 300 ms there, but not by so much that a
    /// fourth frame per second would fit.
    private static let minimumFrameInterval: Double = 1.0 / 3.0

    private let reader = BroadcastFrameReader()
    private let pipeline = LiveOfferPipeline()

    private var lastProcessedSeconds = -Double.greatestFiniteMagnitude

    // MARK: - Lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        lastProcessedSeconds = -Double.greatestFiniteMagnitude
        pipeline.start()
    }

    override func broadcastPaused() {
        pipeline.stop()
        lastProcessedSeconds = -Double.greatestFiniteMagnitude
    }

    override func broadcastResumed() {
        // `start` re-reads settings. The driver may have paused precisely to go
        // and change their fuel price, and every verdict depends on it.
        pipeline.start()
        lastProcessedSeconds = -Double.greatestFiniteMagnitude
    }

    override func broadcastFinished() {
        pipeline.stop()
        reader.releaseResources()
    }

    // MARK: - Frames

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        // Audio arrives here too when the driver has the microphone on. There
        // is nothing in it for us, and the cheapest possible rejection is the
        // point: this method is called sixty times a second.
        guard sampleBufferType == .video else { return }
        guard shouldProcess(sampleBuffer) else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let orientation = Self.orientation(of: sampleBuffer)

        // Deliberately synchronous on ReplayKit's own delivery thread.
        //
        // Handing the frame to a queue would mean holding a reference to
        // ReplayKit's buffer past this call, which starves its pool and is the
        // classic way to make a broadcast stutter and then die. Blocking here
        // gives the same back-pressure for free — ReplayKit simply drops the
        // frames that arrive while we are busy, which is exactly what the
        // throttle above would have done with them anyway — with no shared
        // state and nothing retained.
        //
        // The pool drains every frame. Vision's intermediates are large enough
        // that letting even two frames' worth coexist puts the peak within
        // reach of the limit.
        autoreleasepool {
            pipeline.consume(reader.readBlocks(from: pixelBuffer, orientation: orientation))
        }
    }

    /// Gated on the sample's presentation timestamp, not on wall clock: it is
    /// the frame's own idea of when it happened, so a burst delivered late
    /// still thins out to three a second instead of all being let through.
    private func shouldProcess(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let now = timestamp.isNumeric ? timestamp.seconds : ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastProcessedSeconds

        // A negative gap means the clock restarted under us. Treat it as due,
        // or the extension sits idle until the new clock catches up with the
        // old one — which, for a session-relative timebase, is never.
        guard elapsed >= Self.minimumFrameInterval || elapsed < 0 else { return false }

        lastProcessedSeconds = now
        return true
    }

    /// ReplayKit delivers the frame in the capture device's native orientation
    /// and describes the display orientation in an attachment. Ignoring it
    /// means a rotated phone is cropped along the wrong edge, and the reader
    /// spends the shift OCR-ing half a map.
    private static func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard
            let raw = CMGetAttachment(
                sampleBuffer,
                key: RPVideoSampleOrientationKey as CFString,
                attachmentModeOut: nil
            ) as? NSNumber,
            let orientation = CGImagePropertyOrientation(rawValue: raw.uint32Value)
        else {
            return .up
        }
        return orientation
    }
}

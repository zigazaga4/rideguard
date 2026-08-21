import AVFoundation
import AVKit
import Combine
import UIKit
import RideGuardCore

/// A floating HUD over Bolt and Uber, built out of Picture-in-Picture.
///
/// ## Why a video window
///
/// iOS has no overlay API — `docs/ios-platform-limits.md` spells that out, and
/// it is still true. An app's windows are removed from the screen the moment it
/// is backgrounded. The one window class the system keeps floating above another
/// app is the Picture-in-Picture window, and PiP is not required to contain
/// video: `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`
/// will float an `AVSampleBufferDisplayLayer` that we feed frames we drew
/// ourselves. So the HUD is, as far as iOS is concerned, a video the driver is
/// watching while he uses Bolt.
///
/// ## Be clear-eyed about it
///
/// This is outside what PiP is for. Apple can close it in any release, and the
/// App Store would reject it — background audio with no audio (2.5.4) and PiP
/// with no media are both explicit review triggers. Distribution is TestFlight,
/// and in the EU an alternative marketplace. It is built anyway, because on an
/// iPhone 11 — no Dynamic Island, so no glanceable Live Activity while Bolt is
/// in the foreground — this is the only thing that delivers what the Android
/// build delivers, which is a number in front of the driver's eyes while the
/// offer is still on screen.
///
/// ## The two halves
///
/// The broadcast extension reads the screen and publishes a `LiveVerdict`; this
/// consumes it. Neither can do the other's job — see `LiveVerdict.swift` for why
/// the process split is not a choice.
final class PiPOverlayController: NSObject, ObservableObject {

    /// One overlay per app, and the SwiftUI preview needs to find the layer from
    /// `dismantleUIView`, which is static.
    static let shared = PiPOverlayController()

    // MARK: - State the UI shows

    /// Frames are being produced and the channel is being watched.
    @Published private(set) var isRunning = false
    /// The PiP window is actually on screen. Distinct from `isRunning`: the
    /// driver can swipe the window away and leave the session running.
    @Published private(set) var isOverlayVisible = false
    /// When the last accepted verdict arrived. Nil means nothing yet, which is
    /// the only evidence the app has that the broadcast is or is not running —
    /// there is no API to ask.
    @Published private(set) var lastVerdictAt: Date?
    /// Surfaced in the UI rather than logged. This runs on a phone in a car with
    /// no debugger attached, and "it just did nothing" is not a bug report.
    @Published private(set) var lastError: String?

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    // MARK: - Tuning

    /// 2 fps.
    ///
    /// PiP tears the window down if the stream dries up, so frames must keep
    /// coming even when the number has not changed — but this runs for a whole
    /// shift on a driver's battery, and the figure it shows moves every few
    /// seconds at best. Two frames a second is a rounding error next to the
    /// screen being on, and a new verdict does not wait for the next tick
    /// anyway: `setSnapshot` draws one immediately.
    private static let frameInterval: TimeInterval = 0.5

    /// After this long with nothing published, whatever is on screen stops being
    /// a statement about anything the driver can see, and comes down.
    ///
    /// Longer than an offer card lives (10–15 s) so a quiet extension does not
    /// blank a valid HUD; short enough that a stopped broadcast cannot leave a
    /// stale number floating over an unrelated screen.
    private static let staleAfter: TimeInterval = 30

    // MARK: - Machinery

    /// Owned here, not by the view. PiP dies if its source layer is deallocated,
    /// and SwiftUI is free to tear its views down whenever it likes.
    let displayLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        return layer
    }()

    private let renderer = HudRenderer()
    private let renderQueue = DispatchQueue(label: "com.rideguard.overlay.render", qos: .userInitiated)
    private var frameTimer: DispatchSourceTimer?

    private var pipController: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var wantsOverlay = false

    /// Touched on `renderQueue` only.
    private var snapshot: HudSnapshot = .waiting

    private var lastSequence: UInt64 = 0
    private var lastCapturedAtMs: Int64 = 0

    private override init() {
        super.init()
    }

    // MARK: - Session

    func start() {
        guard !isRunning else {
            showOverlay()
            return
        }

        lastError = nil
        lastVerdictAt = nil
        lastSequence = 0
        lastCapturedAtMs = 0

        // Last night's verdict is still sitting in the App Group container. Left
        // there, it would be read back the instant we start observing and shown
        // as if it were this offer.
        LiveVerdictChannel.clear()
        setSnapshot(.waiting)

        activateAudioSession()
        attachToKeyWindowIfDetached()
        configurePictureInPicture()
        startFrameLoop()

        LiveVerdictChannel.observe { [weak self] verdict in
            self?.handle(verdict)
        }

        isRunning = true
        showOverlay()
    }

    func stop() {
        guard isRunning else { return }

        wantsOverlay = false
        if let pipController, pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        }
        LiveVerdictChannel.stopObserving()
        stopFrameLoop()
        displayLayer.flushAndRemoveImage()
        deactivateAudioSession()

        isRunning = false
        isOverlayVisible = false
        lastVerdictAt = nil
    }

    /// Brings the window back after the driver has swiped it away, without
    /// making him restart the broadcast — which he would have to do by hand, and
    /// which would cost him the offer he is looking at.
    func showOverlay() {
        wantsOverlay = true
        startPictureInPictureIfWanted()
    }

    func hideOverlay() {
        wantsOverlay = false
        pipController?.stopPictureInPicture()
    }

    // MARK: - Picture in Picture

    private func configurePictureInPicture() {
        guard pipController == nil else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            // True on the Simulator, which is where this will first be run.
            lastError = "Picture in Picture is not available on this device."
            return
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // So the HUD appears when the driver switches to Bolt instead of
        // requiring him to have tapped something first.
        controller.canStartPictureInPictureAutomaticallyFromInline = true

        // KVO, not a delay. `isPictureInPicturePossible` only becomes true once
        // the layer is in a window *and* has been given a frame, neither of
        // which has happened at the moment the driver taps Start. Calling
        // `startPictureInPicture()` before then is a silent no-op — no error, no
        // window, nothing to look at.
        possibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async { self?.startPictureInPictureIfWanted() }
        }

        pipController = controller
    }

    private func startPictureInPictureIfWanted() {
        guard wantsOverlay,
              let pipController,
              !pipController.isPictureInPictureActive,
              pipController.isPictureInPicturePossible
        else { return }
        pipController.startPictureInPicture()
    }

    /// Keeps the source layer inside a window when the view that was hosting it
    /// goes away.
    ///
    /// PiP stops if its layer leaves the window hierarchy, and the layer lives in
    /// a SwiftUI view that iOS discards the moment the driver switches tabs.
    /// Two points square in the corner is invisible and still counts as onscreen.
    func attachToKeyWindowIfDetached() {
        guard displayLayer.superlayer == nil, let window = Self.activeKeyWindow else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = CGRect(x: 2, y: 2, width: 2, height: 2)
        window.layer.addSublayer(displayLayer)
        CATransaction.commit()
    }

    private static var activeKeyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows
            .first { $0.isKeyWindow }
    }

    // MARK: - Keeping the process alive

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // `.mixWithOthers` is mandatory, not a nicety. This session exists
            // only to hold the process up behind the PiP window; without the
            // option iOS treats us as the app that is playing, and the driver's
            // music and his navigation voice stop the moment the HUD appears.
            // That gets the app deleted faster than any bug.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            lastError = "Could not hold the audio session: \(error.localizedDescription)"
        }
    }

    private func deactivateAudioSession() {
        // `.notifyOthersOnDeactivation` is what lets a paused music app resume
        // instead of staying silent until the driver notices and taps play.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Frames

    private func startFrameLoop() {
        stopFrameLoop()
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        // Leeway lets the OS coalesce these wakeups with others it was making
        // anyway. Over an eight-hour shift that is the difference between a
        // background HUD you notice on the battery graph and one you do not.
        timer.schedule(deadline: .now(), repeating: Self.frameInterval, leeway: .milliseconds(120))
        timer.setEventHandler { [weak self] in self?.renderFrame() }
        timer.resume()
        frameTimer = timer
    }

    private func stopFrameLoop() {
        frameTimer?.cancel()
        frameTimer = nil
    }

    /// On `renderQueue`.
    private func renderFrame() {
        let duration = CMTime(seconds: Self.frameInterval, preferredTimescale: 600)
        guard let sampleBuffer = renderer.makeSampleBuffer(snapshot, duration: duration) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.enqueue(sampleBuffer)
        }
    }

    /// On the main thread.
    ///
    /// `AVSampleBufferDisplayLayer` is a `CALayer`, and layers are not documented
    /// as thread-safe. The expensive half — laying out glyphs and filling
    /// pixels — has already happened off the main thread, so hopping here costs
    /// microseconds twice a second and removes a class of rare rendering
    /// failures that would be impossible to reproduce on a driver's phone.
    private func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            // The layer fails after a memory warning or a GPU reset and then
            // silently ignores everything enqueued afterwards — the HUD freezes
            // on whatever frame was up, which is worse than showing nothing.
            // Flushing is the only way back.
            displayLayer.flush()
        }
        guard displayLayer.isReadyForMoreMediaData else { return }
        displayLayer.enqueue(sampleBuffer)
        expireStaleVerdict()
    }

    private func setSnapshot(_ next: HudSnapshot) {
        renderQueue.async { [weak self] in
            guard let self, next != self.snapshot else { return }
            self.snapshot = next
            // Draw now rather than waiting for the tick. Half a second out of a
            // ten-second decision is worth one extra frame.
            self.renderFrame()
        }
    }

    // MARK: - The channel

    private func handle(_ verdict: LiveVerdict) {
        guard isRunning, accepts(verdict) else { return }

        lastSequence = verdict.sequence
        if verdict.capturedAtMs > 0 { lastCapturedAtMs = verdict.capturedAtMs }
        lastVerdictAt = Date()

        setSnapshot(verdict.visible ? HudSnapshot(verdict: verdict) : .waiting)
    }

    private func accepts(_ verdict: LiveVerdict) -> Bool {
        if verdict.sequence > lastSequence { return true }

        // A sequence that goes backwards is not a late frame: the counter is
        // monotonic *per broadcast session*, so it restarts at 1 when the driver
        // stops and starts the broadcast while this controller keeps running. A
        // strict rule would then ignore the entire rest of the shift.
        //
        // Wall-clock capture time never goes backwards, so it settles it — and a
        // genuinely late OCR result carries an older capture time and is still
        // correctly dropped, which is the whole point of the gate.
        return verdict.capturedAtMs > 0 && verdict.capturedAtMs > lastCapturedAtMs
    }

    private func expireStaleVerdict() {
        guard let last = lastVerdictAt, Date().timeIntervalSince(last) > Self.staleAfter else { return }
        // Nothing for half a minute: the broadcast was stopped, or the extension
        // was killed. Resetting the gate at the same time is what lets a
        // restarted broadcast — whose sequence starts again at 1 — be picked up
        // without the driver having to restart the overlay too.
        lastVerdictAt = nil
        lastSequence = 0
        lastCapturedAtMs = 0
        setSnapshot(.waiting)
    }
}

// MARK: - Playback delegate

/// There is no timeline here, and every method exists to say so.
///
/// Getting this wrong is the classic way custom-content PiP refuses to start
/// with no error anywhere: the controller asks for a time range, gets something
/// finite or invalid, decides the content is not playable and quietly gives up.
extension PiPOverlayController: AVPictureInPictureSampleBufferPlaybackDelegate {

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // Deliberately inert. A stray tap on the PiP pause button must not be
        // able to freeze the HUD on a number that has since stopped being true.
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        // Infinite in both directions is how AVKit is told "this is live". It is
        // also what hides the scrubber, which is the honest thing: there is
        // nothing here to seek through.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        // Never paused. Reporting paused makes AVKit stop asking for frames.
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // Nothing to do: the HUD is drawn at a fixed size and the system scales
        // it. Re-rendering per window size would burn battery to gain nothing at
        // the two-second glance this is designed for.
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completionHandler: @escaping () -> Void
    ) {
        // Must still call back. AVKit waits on this and stops driving playback
        // if it never arrives.
        completionHandler()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        // False, and this one matters more than it looks. The default is to
        // silence other apps' audio while PiP is up — which would kill the
        // driver's music and his navigation the moment the HUD appeared, undoing
        // the whole point of `.mixWithOthers` on the session.
        false
    }
}

// MARK: - Controller delegate

extension PiPOverlayController: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isOverlayVisible = true
        wantsOverlay = true
        lastError = nil
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isOverlayVisible = false
        lastError = error.localizedDescription
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isOverlayVisible = false
        // Cleared so the KVO handler does not immediately restart a window the
        // driver just dismissed. Coming back to the app also stops PiP, and
        // `canStartPictureInPictureAutomaticallyFromInline` restarts it on the
        // next switch away without needing this flag.
        wantsOverlay = false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // There is no player UI to restore to — the app's own screens are
        // already whatever they were. Reporting success anyway is required;
        // false leaves AVKit believing the transition failed.
        completionHandler(true)
    }
}

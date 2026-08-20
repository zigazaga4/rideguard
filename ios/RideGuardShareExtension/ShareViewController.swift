import UIKit
import SwiftUI
import UniformTypeIdentifiers
import CoreGraphics
import RideGuardCore

//  The share extension: screenshot in, verdict out.
//
//  This is iOS's honest substitute for Android's accessibility capture. It
//  cannot watch the Bolt app — nothing on iOS can — but a driver who takes a
//  screenshot and hits Share gets the same pipeline from `TokenScanner`
//  downwards, and therefore the same verdict, as the Android build.
//
//  Target membership is wired in `ios/project.yml`: this target needs
//  RideGuardCore, the Vision reader in `RideGuard/Capture`, and three files
//  from the app — `App/Persistence.swift` (settings and history live in the
//  App Group), `App/Quick/VerdictCardView.swift` (one card, one rendering) and
//  the `RideGuardLiveActivity` pair. It must carry the same App Group
//  entitlement as the app, or it will read a default vehicle profile and give
//  confidently wrong answers.

final class ShareViewController: UIViewController {

    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()

        let host = UIHostingController(
            rootView: ShareResultView(model: model, onClose: { [weak self] in self?.finish() })
        )
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        host.didMove(toParent: self)

        Task { await model.run(context: extensionContext) }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

/// Drives the extension: pull the image out of the share context, OCR it,
/// parse it, evaluate it, log it.
@MainActor
final class ShareModel: ObservableObject {

    enum State {
        case working
        case verdict(OfferEconomics)
        /// Recognised text is carried along so the driver can see WHAT was
        /// read. "Couldn't read that" teaches nobody anything; showing the OCR
        /// output tells them whether to retake the shot or report a bug.
        case unreadable(reason: String, recognizedText: String)
    }

    @Published private(set) var state: State = .working
    @Published private(set) var decision: HistoryEntry.Decision = .undecided

    private let settingsStore = SettingsStore()
    private let historyStore = HistoryStore()
    private var loggedEntryID: UUID?

    var settings: AppSettings { settingsStore.load() }

    func run(context: NSExtensionContext?) async {
        guard let context else {
            state = .unreadable(reason: "Nothing was shared.", recognizedText: "")
            return
        }

        do {
            let image = try await ShareAttachment.loadImage(from: context)
            try await analyse(image)
        } catch {
            state = .unreadable(
                reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                recognizedText: ""
            )
        }
    }

    private func analyse(_ image: CGImage) async throws {
        let settings = settingsStore.load()

        // Vision on a 3 MP screenshot takes a few hundred milliseconds; off the
        // main actor so the sheet stays interactive while it works.
        let result = try await Task.detached(priority: .userInitiated) {
            try ScreenshotOfferReader().read(
                cgImage: image,
                fallbackPlatform: settings.defaultPlatform,
                fareIsNet: { settings.fareIsNet(for: $0) }
            )
        }.value

        guard let offer = result.offer else {
            state = .unreadable(
                reason: result.blocks.isEmpty
                    ? "No text found in that image."
                    : "Found text, but no fare and distance that look like an offer card.",
                recognizedText: result.recognizedText
            )
            return
        }

        let calculator = ProfitCalculator(vehicle: settings.vehicle, thresholds: settings.thresholds)

        guard let economics = calculator.evaluate(offer) else {
            state = .unreadable(
                reason: "Read the card, but not a fare and a distance together — there is nothing to do the arithmetic on.",
                recognizedText: result.recognizedText
            )
            return
        }

        state = .verdict(economics)

        // Logged immediately, as undecided. The driver looked at this offer;
        // that is worth recording even if they dismiss the sheet without
        // saying what they did.
        let entry = HistoryEntry(economics: economics, source: .screenshot)
        loggedEntryID = entry.id
        historyStore.append(entry)

        // Best-effort, and allowed to do nothing: whether an app extension may
        // start a Live Activity varies by OS version. The verdict is already on
        // screen, so a failure here costs the driver nothing.
        LiveActivityController.show(economics, enabled: settings.liveActivityEnabled)
    }

    func record(_ decision: HistoryEntry.Decision) {
        self.decision = decision
        guard let loggedEntryID else { return }
        historyStore.updateDecision(decision, for: loggedEntryID)
    }
}

/// Gets a `CGImage` out of whatever the share sheet handed us.
///
/// Providers are inconsistent: Photos offers image data, the screenshot editor
/// offers a UIImage, Files offers a URL. All three are handled rather than
/// assuming one, because a failure here reads to the driver as "the app is
/// broken".
enum ShareAttachment {

    static func loadImage(from context: NSExtensionContext) async throws -> CGImage {
        let providers = (context.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }

        guard let provider = providers.first else {
            throw VisionTextReader.ReadError.notAnImage
        }
        return try await loadImage(from: provider)
    }

    private static func loadImage(from provider: NSItemProvider) async throws -> CGImage {
        // Prefer the concrete registered type (public.png for screenshots) —
        // asking for the abstract public.image makes some providers transcode.
        let identifier = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        } ?? UTType.image.identifier

        let item: NSSecureCoding = try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let item {
                    continuation.resume(returning: item)
                } else {
                    continuation.resume(throwing: VisionTextReader.ReadError.notAnImage)
                }
            }
        }

        switch item {
        case let data as Data:
            return try VisionTextReader.decode(data)
        case let url as URL:
            return try VisionTextReader.decode(contentsOf: url)
        case let image as UIImage:
            guard let cgImage = image.cgImage else { throw VisionTextReader.ReadError.notAnImage }
            return cgImage
        default:
            throw VisionTextReader.ReadError.notAnImage
        }
    }
}

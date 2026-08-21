import AVFoundation
import SwiftUI
import UIKit

/// Shows the real PiP source layer inline, at the aspect ratio it will float at.
///
/// Two jobs, and the second is the load-bearing one:
///
/// 1. The driver sees exactly what is about to appear over Bolt, before he is
///    driving, which is the only moment he can check it.
/// 2. PiP will not start unless its source layer is in a window. This is that
///    window. The controller keeps the layer alive across view teardown; this
///    view only borrows it.
struct HudPreview: UIViewRepresentable {

    func makeUIView(context: Context) -> HudPreviewHostView {
        let view = HudPreviewHostView()
        view.adopt(PiPOverlayController.shared.displayLayer)
        return view
    }

    func updateUIView(_ view: HudPreviewHostView, context: Context) {
        // Re-adopting is not redundant: coming back to this tab finds the layer
        // parked in the key window, and a layer has exactly one superlayer.
        view.adopt(PiPOverlayController.shared.displayLayer)
    }

    static func dismantleUIView(_ view: HudPreviewHostView, coordinator: ()) {
        // Order matters. Detaching first is what makes the controller's
        // "is it detached?" check true, and leaving the layer to die with this
        // view would take a running PiP window down with it.
        view.release()
        PiPOverlayController.shared.attachToKeyWindowIfDetached()
    }
}

final class HudPreviewHostView: UIView {

    private weak var hosted: CALayer?

    func adopt(_ layer: CALayer) {
        guard layer.superlayer !== self.layer else { return }
        hosted = layer
        // `addSublayer` moves the layer off whatever it was attached to.
        self.layer.addSublayer(layer)
        setNeedsLayout()
    }

    func release() {
        hosted?.removeFromSuperlayer()
        hosted = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Implicit animations on a video layer's frame produce a visible slide
        // on every rotation and every time SwiftUI re-lays this out, and they
        // fight the PiP transition animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted?.frame = bounds
        CATransaction.commit()
    }
}

import ReplayKit
import SwiftUI
import UIKit

/// The system's own "start a broadcast" button.
///
/// It has to be Apple's button, not ours. There is no API that starts a
/// broadcast — none, not with any entitlement — because the whole point of the
/// design is that the user, not the app, decides when their screen is being
/// read. `RPSystemBroadcastPickerView` is the only way in, and it must be tapped
/// by a finger.
///
/// `preferredExtension` is what turns the sheet from a list of every
/// broadcast-capable app on the phone into a single RideGuard entry — worth
/// having when the driver is doing this at the start of every shift.
struct BroadcastPickerButton: UIViewRepresentable {
    /// Must match the broadcast extension's `PRODUCT_BUNDLE_IDENTIFIER`. A typo
    /// here is not an error: the sheet simply opens on the full list, which
    /// still works but hands the driver a decision he should not have to make.
    let preferredExtension = "com.rideguard.app.broadcast"

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 64, height: 64)
        )
        picker.preferredExtension = preferredExtension
        // Nothing here needs audio, and offering the microphone toggle invites a
        // driver to record his own car for no benefit.
        picker.showsMicrophoneButton = false
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {}
}

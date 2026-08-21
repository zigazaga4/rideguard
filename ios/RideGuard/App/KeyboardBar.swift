import SwiftUI
import UIKit

/// One Done button above the keyboard, per screen.
///
/// The obvious-looking version of this — putting the toolbar on the text field
/// itself, so the field is self-sufficient — is wrong, and wrong in a way that
/// only shows up on a real device. `ToolbarItemGroup(placement: .keyboard)`
/// contributes to the screen's keyboard accessory, not to the field's, so a
/// Form holding two decimal fields renders **two** Done buttons side by side,
/// and Settings, with four, renders four.
///
/// So it belongs exactly once, at the root of each screen that has typing in
/// it. `.decimalPad` has no return key, which is what makes this mandatory
/// rather than a nicety: without it there is no way at all to put the keyboard
/// away.
///
/// Dismissal goes through `resignFirstResponder` rather than a `@FocusState`
/// so this composes with any screen without every field having to publish its
/// focus upward — the button does not need to know *which* field is up, only
/// that one is.
extension View {
    func keyboardDoneBar() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
                .fontWeight(.semibold)
            }
        }
    }
}

/// Tracks whether the software keyboard is on screen.
///
/// Used to get fixed bottom chrome out of the way. SwiftUI's keyboard avoidance
/// lifts a bottom bar to sit *on top of* the keyboard, which looks broken and
/// steals the row of screen the driver needs to see what he is typing. No app
/// that handles keyboards well does that; they hide the bar instead.
@MainActor
final class KeyboardObserver: ObservableObject {
    @Published private(set) var isVisible = false

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: UIResponder.keyboardWillShowNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isVisible = true }
            }
        )
        observers.append(
            center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isVisible = false }
            }
        )
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

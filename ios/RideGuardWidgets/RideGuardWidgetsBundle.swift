import SwiftUI
import WidgetKit

//  The extension exists solely to host the Live Activity. There is no Home
//  Screen widget: a widget can only show what the app already knows, and what
//  the app knows about the next offer is nothing.

@main
struct RideGuardWidgetsBundle: WidgetBundle {
    var body: some Widget {
        // The whole bundle is behind an availability check because the app
        // deploys to iOS 16.0 and Live Activities need 16.2. On 16.0/16.1 the
        // extension installs and does nothing, which is the intended outcome.
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            VerdictLiveActivity()
        }
        #endif
    }
}

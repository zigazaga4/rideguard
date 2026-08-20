// swift-tools-version: 5.9

import PackageDescription

// RideGuardCore is the iOS twin of the Kotlin `:domain` module: models, number
// parsing, token scanning, the platform parsers, the profit calculator and the
// update-manifest rules. Same maths, same verdicts, same numbers as Android for
// the same input.
//
// It is a SwiftPM library rather than an Xcode framework target for one reason:
// `swift test` runs the whole domain suite from a terminal in about a second,
// with no simulator, no signing and no device. That is the same bargain the
// Kotlin module makes by refusing to import anything from `android.*`.
//
// So the rule for this target is absolute: **Foundation and nothing else.**
// Vision lives in `RideGuard/Capture`, SwiftUI in `RideGuard/App`, ActivityKit
// in `RideGuardLiveActivity`. The moment Core imports one of them, the domain
// tests need a Mac and the parser work becomes device work again.
//
// SwiftPM cannot produce an .app or an .appex, so the app, the share extension
// and the widget extension are Xcode targets. They are described in
// `project.yml` and generated with XcodeGen — see `README.md`.
let package = Package(
    name: "RideGuard",
    platforms: [
        // Matches the Xcode targets. macOS is listed only so the suite can run
        // on a Mac without booting a simulator; the package also builds on
        // Linux, where these declarations are ignored.
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "RideGuardCore", targets: ["RideGuardCore"]),
    ],
    targets: [
        .target(
            name: "RideGuardCore",
            path: "RideGuard/Core"
        ),
        .testTarget(
            name: "RideGuardTests",
            dependencies: ["RideGuardCore"],
            path: "RideGuardTests"
        ),
    ]
)

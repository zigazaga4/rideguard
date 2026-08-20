// swift-tools-version: 5.9

import PackageDescription

// RideGuardCore is the iOS twin of the Kotlin `:domain` module: models, number
// parsing, token scanning, the platform parsers and the profit calculator.
// Same maths, same verdicts, same numbers as Android for the same input.
//
// It is a SwiftPM library rather than an Xcode framework target for one
// reason: `swift test` runs the whole domain suite from a terminal in about a
// second, with no simulator, no signing and no device. Parser work stops being
// device work. That is the same bargain the Kotlin module makes by refusing to
// import anything from `android.*`.
//
// The SwiftUI app under `RideGuard/App` and the share extension under
// `RideGuardShareExtension` are NOT SwiftPM targets — SwiftPM cannot produce an
// .app or an .appex. They are Xcode targets that depend on this package:
//
//   RideGuard.app          -> RideGuardCore + RideGuard/App/**
//   RideGuardShare.appex   -> RideGuardCore + RideGuardShareExtension/**
//                             + RideGuard/App/Quick/VerdictCardView.swift
//                             + RideGuard/App/Persistence.swift
//
// Both app targets need the App Group in `Persistence.appGroupIdentifier`, or
// the extension writes history the app will never see.
let package = Package(
    name: "RideGuard",
    platforms: [
        // iOS 17 for `@Observable`-era SwiftUI; macOS is listed only so the
        // test suite can run on a Mac without booting a simulator.
        .iOS(.v17),
        .macOS(.v14),
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

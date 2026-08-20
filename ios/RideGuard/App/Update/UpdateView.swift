import SwiftUI
import RideGuardCore

/// Updates, outside the App Store.
///
/// The App Store is not in this picture at all: builds are signed with a
/// distribution profile and installed over the air from a GitHub release, the
/// same release the Android APK comes from. `docs/ios-updates.md` covers what
/// that costs and what has to be true for the Install button to work.
///
/// Nothing here happens on its own. Tapping Install hands iOS an
/// `itms-services://` URL and iOS asks the driver to confirm — an app that
/// replaces itself unannounced on somebody's work phone mid-shift is not a
/// convenience, it is an outage.
@MainActor
final class UpdateViewModel: ObservableObject {
    @Published private(set) var result: UpdateCheckResult?
    @Published private(set) var isChecking = false

    private let checker: UpdateChecker

    init(checker: UpdateChecker = UpdateChecker()) {
        self.checker = checker
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        result = await checker.check()
        isChecking = false
    }
}

struct UpdateView: View {
    @StateObject private var model = UpdateViewModel()
    @Environment(\.openURL) private var openURL
    @State private var confirmingInstall: UpdateManifest.IOSRelease?

    private let installed = AppVersion.current()

    var body: some View {
        Form {
            installedSection
            statusSection
            if let notes = model.result?.manifest?.notes, !notes.isEmpty {
                Section("What changed") {
                    Text(notes).font(.callout)
                }
            }
            explanationSection
        }
        .navigationTitle("Updates")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.check() }
        .refreshable { await model.check() }
        .confirmationDialog(
            "Install RideGuard \(confirmingInstall?.version ?? "")?",
            isPresented: Binding(
                get: { confirmingInstall != nil },
                set: { if !$0 { confirmingInstall = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmingInstall
        ) { release in
            Button("Install") { install(release) }
            Button("Not now", role: .cancel) {}
        } message: { _ in
            Text("iOS will ask you to confirm, then download and replace the app. Your settings and history stay where they are. Do not do this while you are waiting on an offer — the app closes while it installs.")
        }
    }

    // MARK: - Sections

    private var installedSection: some View {
        Section("Installed") {
            LabeledContent("Version", value: installed.version)
            LabeledContent("Build", value: "\(installed.build)")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if model.isChecking && model.result == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking GitHub…").foregroundStyle(.secondary)
                }
            } else if let result = model.result {
                statusRow(result.status)
                if case .available(let release) = result.status {
                    LabeledContent("New version", value: "\(release.version) (\(release.build))")
                    if let size = release.sizeBytes {
                        LabeledContent("Download", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if let published = result.manifest?.publishedDate {
                        LabeledContent("Published", value: published.formatted(date: .abbreviated, time: .shortened))
                    }
                    installButton(release)
                }
                Button {
                    Task { await model.check() }
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
                .disabled(model.isChecking)
            }
        } header: {
            Text("Latest release")
        } footer: {
            if let result = model.result, result.manifest?.mandatory == true, result.status.isActionable {
                Text("Marked as an important update — the previous build has a problem worth fixing.")
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func statusRow(_ status: UpdateStatus) -> some View {
        switch status {
        case .upToDate:
            Label("You are on the newest build", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .available:
            Label("An update is available", systemImage: "arrow.down.circle")
                .foregroundStyle(.blue)
        case .noReleaseForThisPlatform:
            Label("This release is Android only. Nothing to install here.", systemImage: "iphone.slash")
                .foregroundStyle(.secondary)
        case .unsupportedSchema(let found, let supported):
            Label(
                "The update file is written for a newer RideGuard (format \(found), this build reads \(supported)). Install the latest build by hand from the GitHub release page.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        case .requiresNewerOS(let required, let current):
            Label(
                "The new build needs iOS \(required); this iPhone is on \(current). Update iOS first.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        case .couldNotCheck(let reason):
            // Grey and small on purpose. Failing to reach GitHub changes
            // nothing about the app the driver is holding.
            Label("Couldn't check. \(reason)", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
                .font(.footnote)
        }
    }

    @ViewBuilder
    private func installButton(_ release: UpdateManifest.IOSRelease) -> some View {
        if release.otaInstallURL != nil {
            Button {
                confirmingInstall = release
            } label: {
                Label("Install \(release.version)", systemImage: "square.and.arrow.down")
                    .fontWeight(.semibold)
            }
        } else {
            // An `itms-services://` install whose manifest is not on HTTPS
            // fails with a message that tells the driver nothing. Better to
            // never offer the button and say why.
            Label(
                "The published install link is not HTTPS, so iOS will refuse it. That is a mistake in the release, not on your phone.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
        }
    }

    private var explanationSection: some View {
        Section {
            Label("Updates come from GitHub, not the App Store", systemImage: "shippingbox")
            Label("Nothing installs by itself — you tap, then iOS asks", systemImage: "hand.raised")
            Label("Your settings and history survive the update", systemImage: "tray.full")
        } footer: {
            Text("The install uses Apple's over-the-air mechanism, which needs the build to be signed for this specific iPhone. If the install fails with \u{201C}cannot connect\u{201D} or \u{201C}unable to install\u{201D}, the signing profile no longer covers this device — see docs/ios-updates.md.")
        }
    }

    private func install(_ release: UpdateManifest.IOSRelease) {
        guard let url = release.otaInstallURL else { return }
        openURL(url)
        confirmingInstall = nil
    }
}

#Preview {
    NavigationStack { UpdateView() }
}

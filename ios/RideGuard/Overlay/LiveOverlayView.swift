import SwiftUI

/// The screen that starts and stops the live HUD.
///
/// The copy here is deliberately blunt about what iOS does and does not do. A
/// driver who believes this starts by itself will put the phone in the mount,
/// open Bolt, and get nothing — and he will find that out in the middle of a
/// shift, not here. Every limitation on this screen is one he would otherwise
/// discover the expensive way.
struct LiveOverlayView: View {
    @ObservedObject private var controller = PiPOverlayController.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    preview
                    if !controller.isSupported { unsupportedNote }
                    status
                    broadcastStep
                    overlayStep
                    if let error = controller.lastError { errorNote(error) }
                    limitations
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Live HUD")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(spacing: 8) {
            HudPreview()
                .aspectRatio(
                    HudRenderer.renderSize.width / HudRenderer.renderSize.height,
                    contentMode: .fit
                )
                .frame(maxWidth: 320)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )
            // The inline layer goes dark while PiP owns the content. Saying so
            // costs one line and saves a driver concluding it has broken.
            Text(controller.isOverlayVisible
                 ? "The HUD is floating over everything now, so this preview is empty."
                 : "This is the window that will float over Bolt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Status

    private var status: some View {
        // Ticks once a second so "12s ago" is true rather than whenever SwiftUI
        // last felt like redrawing. A stale timestamp on this screen would be
        // the one thing worse than no timestamp: it looks like it is working.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let receiving = isReceiving(at: now)

            VStack(spacing: 10) {
                statusRow(
                    label: "Screen reading",
                    value: receiving ? "verdicts arriving" : "nothing yet",
                    ok: receiving
                )
                Divider()
                statusRow(
                    label: "HUD window",
                    value: controller.isOverlayVisible
                        ? "floating"
                        : (controller.isRunning ? "hidden" : "off"),
                    ok: controller.isOverlayVisible
                )
                Divider()
                statusRow(
                    label: "Last verdict",
                    value: controller.lastVerdictAt.map { relative($0, now: now) } ?? "—",
                    ok: receiving
                )
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    private func statusRow(label: String, value: String, ok: Bool) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer(minLength: 12)
            Circle()
                .fill(ok ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ok ? Color.primary : Color.secondary)
        }
    }

    /// There is no API that answers "is a broadcast running?", so this is
    /// inferred from verdicts arriving. Labelled honestly on screen for the same
    /// reason: a green dot that means "probably" must not read as "definitely".
    private func isReceiving(at now: Date) -> Bool {
        guard let last = controller.lastVerdictAt else { return false }
        return now.timeIntervalSince(last) < 30
    }

    // MARK: - Steps

    private var broadcastStep: some View {
        step(number: "1", title: "Start the screen broadcast") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Tap this, choose RideGuard, then Start Broadcast.")
                    .font(.subheadline)

                HStack {
                    Spacer()
                    BroadcastPickerButton()
                        .frame(width: 64, height: 64)
                        .background(
                            Circle().fill(Color(.tertiarySystemFill))
                        )
                    Spacer()
                }

                Text("""
                RideGuard cannot start this for you, and no app can — iOS gives the \
                decision to you and only you. You must do it again after every restart, \
                after a phone call ends the broadcast, and any time iOS stops it. While \
                it runs, the red recording indicator stays on your screen. That is iOS, \
                not us.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)

                Label(
                    "Nothing leaves the phone. The card is read on the device and thrown away.",
                    systemImage: "lock.fill"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var overlayStep: some View {
        step(number: "2", title: "Show the HUD") {
            VStack(alignment: .leading, spacing: 12) {
                if controller.isRunning {
                    Text("Switch to Bolt or Uber. The HUD floats on top of it.")
                        .font(.subheadline)
                } else {
                    Text("Turn it on here, then switch to Bolt or Uber.")
                        .font(.subheadline)
                }

                HStack(spacing: 12) {
                    if controller.isRunning {
                        Button(role: .destructive) {
                            controller.stop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        // The window is a system window: a swipe dismisses it and
                        // nothing in the app can prevent that. Getting it back
                        // must not cost him the broadcast, which he would have to
                        // restart by hand while driving.
                        Button {
                            controller.showOverlay()
                        } label: {
                            Label("Show it again", systemImage: "pip.enter").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.isOverlayVisible)
                    } else {
                        Button {
                            controller.start()
                        } label: {
                            Label("Start the HUD", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!controller.isSupported)
                    }
                }
                .controlSize(.large)
            }
        }
    }

    private func step<Content: View>(
        number: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(number)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.accentColor))
                Text(title).font(.headline)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Notes

    private var unsupportedNote: some View {
        Label(
            "This device has no Picture in Picture, so the floating HUD cannot run here. Quick check still works.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private func errorNote(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.bubble")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.red.opacity(0.10))
            )
    }

    private var limitations: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What this actually is")
                .font(.subheadline.weight(.semibold))
            Text("""
            The HUD is a Picture-in-Picture window, because that is the only kind of \
            window iOS lets float over another app. So it behaves like one: you can drag \
            it, iOS decides where it snaps, and tapping it does nothing on purpose. \
            Judging an offer is still your call — this only shows you what the numbers \
            come to.
            """)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 2 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        return minutes == 1 ? "1 min ago" : "\(minutes) min ago"
    }
}

#Preview {
    LiveOverlayView()
}

import SwiftUI
import RideGuardCore

/// The sheet the driver sees after sharing a screenshot.
///
/// One screen, no navigation, big buttons: this appears while the offer timer
/// on the other app is still counting down. The verdict card is the same view
/// the app uses, deliberately — a driver should never have to learn two
/// renderings of the same number.
struct ShareResultView: View {
    @ObservedObject var model: ShareModel
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    switch model.state {
                    case .working:
                        working
                    case .verdict(let economics):
                        VerdictCardView(economics: economics)
                        decisionButtons
                        platformNote(economics)
                    case .unreadable(let reason, let recognizedText):
                        unreadable(reason: reason, recognizedText: recognizedText)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("RideGuard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose).fontWeight(.semibold)
                }
            }
        }
    }

    private var working: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Reading the offer…")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("On-device. Nothing is uploaded.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var decisionButtons: some View {
        HStack(spacing: 12) {
            Button {
                model.record(.declined)
                onClose()
            } label: {
                Label("Skipped", systemImage: "xmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                model.record(.accepted)
                onClose()
            } label: {
                Label("Took it", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
    }

    /// The platform was guessed from the text on the screenshot, and the
    /// commission rate follows from it — so say which one was assumed rather
    /// than presenting the number as if it were certain.
    private func platformNote(_ economics: OfferEconomics) -> some View {
        Text("Read as a \(economics.offer.platform.displayName) offer, "
             + (economics.offer.fareIsNet ? "with the fare already net of commission." : "with commission taken off before costs.")
             + " Change that in Settings if it is wrong.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func unreadable(reason: String, recognizedText: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("Could not read that offer")
                    .font(.headline)
            } icon: {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
            }

            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("What helps")
                    .font(.subheadline.weight(.semibold))
                Text("Capture the whole offer card — the fare, the pickup distance AND the trip distance. A cropped shot that shows only one distance is not enough to charge the cost of getting to the passenger, which is the entire point.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("You can always type the numbers on the Quick tab instead.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !recognizedText.isEmpty {
                DisclosureGroup("What was actually recognised") {
                    Text(recognizedText)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

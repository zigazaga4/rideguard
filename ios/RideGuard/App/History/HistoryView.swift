import SwiftUI
import RideGuardCore

/// What actually happened, grouped by day.
///
/// The point of keeping history is not nostalgia: after a week the totals tell
/// a driver whether their thresholds are set anywhere near reality. Somebody
/// declining 80% of offers has set the bar too high and is idling; somebody
/// accepting everything is not using the app at all.
struct HistoryView: View {
    @EnvironmentObject private var state: AppState
    @State private var confirmingClear = false

    private var days: [Date] { state.days() }

    var body: some View {
        NavigationStack {
            Group {
                if state.history.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !state.history.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Clear", role: .destructive) { confirmingClear = true }
                    }
                }
            }
            .confirmationDialog("Delete all history?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { state.clearHistory() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Shift totals are computed from these rows. This cannot be undone.")
            }
        }
    }

    private var list: some View {
        List {
            ForEach(days, id: \.self) { day in
                let entries = state.entries(on: day)
                Section {
                    ForEach(entries) { entry in
                        HistoryRow(entry: entry) { decision in
                            state.setDecision(decision, for: entry.id)
                        }
                    }
                    .onDelete { offsets in
                        state.delete(offsets.map { entries[$0] })
                    }
                } header: {
                    Text(day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                } footer: {
                    ShiftTotalsView(summary: ShiftSummary(entries: entries))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Hand-rolled rather than `ContentUnavailableView`, which is iOS 17 and
    /// would drag the whole app's deployment target up with it for one empty
    /// state. Drivers keep phones a long time.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("No offers yet")
                .font(.headline)
            Text("Check an offer on the Quick tab, or start the live HUD and let it read one, and it lands here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let onDecision: (HistoryEntry.Decision) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Colour AND symbol, for the same reason as the verdict card.
            Image(systemName: entry.verdict.symbol)
                .foregroundStyle(entry.verdict.tint)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(NumberParsing.formatMoney(entry.net, currency: entry.currency))
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(entry.net < 0 ? Color.red : Color.primary)
                    Text("net")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(entry.capturedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                decisionMenu
            }
        }
        .padding(.vertical, 2)
    }

    private var detailLine: String {
        var parts = [
            entry.platform.displayName,
            "\(NumberParsing.formatRate(entry.totalKm, decimals: 1)) km",
            "\(NumberParsing.formatRate(entry.netPerKm)) \(entry.currency)/km",
        ]
        if let perHour = entry.netPerHour {
            parts.append("\(NumberParsing.formatRate(perHour, decimals: 0)) \(entry.currency)/h")
        }
        if entry.source == .screenshot { parts.append("screenshot") }
        return parts.joined(separator: " · ")
    }

    private var decisionMenu: some View {
        Menu {
            Button { onDecision(.accepted) } label: { Label("Accepted", systemImage: "checkmark") }
            Button { onDecision(.declined) } label: { Label("Declined", systemImage: "xmark") }
            Button { onDecision(.undecided) } label: { Label("Not decided", systemImage: "questionmark") }
        } label: {
            Text(decisionLabel)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(decisionTint.opacity(0.18)))
                .foregroundStyle(decisionTint)
        }
    }

    private var decisionLabel: String {
        switch entry.decision {
        case .accepted: return "TOOK IT"
        case .declined: return "SKIPPED"
        case .undecided: return "SET"
        }
    }

    private var decisionTint: Color {
        switch entry.decision {
        case .accepted: return .green
        case .declined: return .secondary
        case .undecided: return .accentColor
        }
    }
}

/// Only accepted rides count towards money and distance — a shift is what you
/// drove, not what you were offered.
private struct ShiftTotalsView: View {
    let summary: ShiftSummary

    var body: some View {
        HStack(spacing: 14) {
            total(NumberParsing.formatMoney(summary.netEarned, currency: summary.currency), "net earned")
            total(summary.netPerHour.map { NumberParsing.formatRate($0, decimals: 0) + " " + summary.currency + "/h" } ?? "—", "per hour")
            total("\(summary.accepted)/\(summary.evaluated)", "taken")
        }
        .padding(.top, 6)
    }

    private func total(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
            Text(caption).font(.caption2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    HistoryView().environmentObject(AppState())
}

import SwiftUI
import RideGuardCore

/// The primary interaction on iOS.
///
/// Android reads the offer card off the screen and floats a verdict over it.
/// iOS cannot do either (`docs/ios-platform-limits.md`), so the driver types
/// five numbers instead. That constrains the design hard: five fields, decimal
/// keypad, no navigation, verdict updating live underneath. A driver has
/// ten-odd seconds and one thumb.
struct QuickEntryView: View {
    @EnvironmentObject private var state: AppState

    @State private var platform: Platform = .bolt
    @State private var fareText = ""
    @State private var pickupKmText = ""
    @State private var pickupMinText = ""
    @State private var tripKmText = ""
    @State private var tripMinText = ""
    @State private var justLogged = false
    @State private var lastDraft: QuickEntryDraft?

    private let draftStore = QuickEntryDraftStore()

    @FocusState private var focused: Field?

    private enum Field: Hashable, CaseIterable {
        case fare, pickupKm, pickupMin, tripKm, tripMin
    }

    /// Parsed with the domain's own parser, not `Double(_:)` — a Romanian
    /// driver types "17,50" because that is what Bolt showed them, and the
    /// decimal keypad on a Romanian keyboard emits a comma.
    private var fare: Double? { NumberParsing.parseDecimal(fareText) }
    private var pickupKm: Double? { NumberParsing.parseDecimal(pickupKmText) }
    private var pickupMin: Double? { NumberParsing.parseDecimal(pickupMinText) }
    private var tripKm: Double? { NumberParsing.parseDecimal(tripKmText) }
    private var tripMin: Double? { NumberParsing.parseDecimal(tripMinText) }

    private var economics: OfferEconomics? {
        guard let fare, fare > 0 else { return nil }
        // Stricter than the calculator on purpose. `RideOffer.chargeableKm`
        // falls back to the paid leg alone when a PARSE could not find the
        // pickup distance, and marks the result down for it. Here there is no
        // parse: the driver either knows the pickup distance or can type 0.
        // Quietly costing a hand-typed offer on the trip leg only would flatter
        // exactly the offers this app exists to catch.
        guard pickupKm != nil, tripKm != nil else { return nil }
        let offer = state.makeOffer(
            platform: platform,
            fare: fare,
            pickupKm: pickupKm,
            pickupMin: pickupMin,
            tripKm: tripKm,
            tripMin: tripMin
        )
        return state.evaluate(offer)
    }

    private var hasAnyInput: Bool {
        ![fareText, pickupKmText, pickupMinText, tripKmText, tripMinText].allSatisfy(\.isEmpty)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    platformPicker
                    fareCard
                    legsCard
                    reuseLastChip
                    verdictSection
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Quick check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear", role: .destructive, action: clear)
                        .disabled(!hasAnyInput)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Next") { focusNext() }
                    Spacer()
                    Button("Done") { focused = nil }
                }
            }
            .onAppear(perform: restoreDraft)
        }
    }

    // MARK: - Input

    private var platformPicker: some View {
        Picker("Platform", selection: $platform) {
            ForEach(Platform.selectable, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.top, 8)
    }

    private var fareCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fare on the card")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                // Restating the setting here is not clutter: whether the
                // displayed fare is what the driver keeps or what the passenger
                // pays changes the answer by a fifth, and it is the single
                // easiest thing to have configured wrong.
                Text(state.settings.fareIsNet(for: platform) ? "what you keep" : "treated as gross")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("0", text: $fareText)
                    .keyboardType(.decimalPad)
                    .focused($focused, equals: .fare)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text(state.settings.vehicle.currency)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var legsCard: some View {
        VStack(spacing: 14) {
            legRow(
                title: "Pickup (to the passenger)",
                subtitle: "the leg nobody pays you for",
                km: $pickupKmText,
                kmField: .pickupKm,
                min: $pickupMinText,
                minField: .pickupMin
            )
            Divider()
            legRow(
                title: "Trip (with the passenger)",
                subtitle: "the paid leg",
                km: $tripKmText,
                kmField: .tripKm,
                min: $tripMinText,
                minField: .tripMin
            )
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func legRow(
        title: String,
        subtitle: String,
        km: Binding<String>,
        kmField: Field,
        min: Binding<String>,
        minField: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                unitField(placeholder: "km", text: km, field: kmField, unit: "km")
                unitField(placeholder: "min", text: min, field: minField, unit: "min")
            }
        }
    }

    private func unitField(placeholder: String, text: Binding<String>, field: Field, unit: String) -> some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .focused($focused, equals: field)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.trailing)
            Text(unit).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.tertiarySystemFill)))
    }

    // MARK: - Reusing the last entry

    /// Offered, never applied automatically.
    ///
    /// The legs repeat all evening — the same driver works the same patch —
    /// but silently prefilling them means a distracted driver reads a verdict
    /// for the previous offer with this offer's fare, which is worse than no
    /// help at all. One tap costs nothing and cannot lie.
    @ViewBuilder
    private var reuseLastChip: some View {
        if let lastDraft, lastDraft.hasLegs, !hasAnyLegInput {
            Button {
                pickupKmText = lastDraft.pickupKm
                pickupMinText = lastDraft.pickupMin
                tripKmText = lastDraft.tripKm
                tripMinText = lastDraft.tripMin
            } label: {
                Label("Same legs as last time · \(lastDraft.summary)", systemImage: "arrow.counterclockwise")
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var hasAnyLegInput: Bool {
        ![pickupKmText, pickupMinText, tripKmText, tripMinText].allSatisfy(\.isEmpty)
    }

    // MARK: - Verdict

    @ViewBuilder
    private var verdictSection: some View {
        if let economics {
            VerdictCardView(economics: economics)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: economics.net)

            HStack(spacing: 12) {
                Button {
                    log(.declined)
                } label: {
                    Label("Declined", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    log(.accepted)
                } label: {
                    Label("Accepted", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)

            if justLogged {
                Label("Logged to history", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        } else {
            missingInputHint
        }
    }

    private var missingInputHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(hintText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var hintText: String {
        if fare == nil { return "Type the fare to see what is actually left of it." }
        // Refusing to guess a zero-km pickup is a deliberate rule: a missing
        // deadhead leg flatters the offer exactly when the driver needs the
        // truth. If the passenger really is at the kerb, type 0.
        return "Add both distances — to the passenger and with them — so the fuel is charged on every kilometre you actually drive. If they are already at your window, type 0 for the pickup."
    }

    // MARK: - Actions

    private func log(_ decision: HistoryEntry.Decision) {
        guard let economics else { return }
        state.log(economics, source: .manual, decision: decision)
        saveDraft()
        LiveActivityController.show(economics, enabled: state.settings.liveActivityEnabled)
        withAnimation { justLogged = true }
        focused = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { justLogged = false }
            clear()
        }
    }

    private func restoreDraft() {
        let saved = draftStore.load()
        lastDraft = saved
        // The platform IS restored outright — a driver works one app for hours
        // and re-picking it every time is friction with no upside. The numbers
        // are not: see `reuseLastChip`.
        platform = saved?.platform ?? state.settings.defaultPlatform
    }

    private func saveDraft() {
        let draft = QuickEntryDraft(
            platform: platform,
            pickupKm: pickupKmText,
            pickupMin: pickupMinText,
            tripKm: tripKmText,
            tripMin: tripMinText
        )
        draftStore.save(draft)
        lastDraft = draft
    }

    private func clear() {
        fareText = ""
        pickupKmText = ""
        pickupMinText = ""
        tripKmText = ""
        tripMinText = ""
        justLogged = false
        focused = nil
    }

    private func focusNext() {
        let order = Array(Field.allCases)
        guard let current = focused, let index = order.firstIndex(of: current) else {
            focused = .fare
            return
        }
        focused = index + 1 < order.count ? order[index + 1] : nil
    }
}

#Preview {
    QuickEntryView().environmentObject(AppState())
}

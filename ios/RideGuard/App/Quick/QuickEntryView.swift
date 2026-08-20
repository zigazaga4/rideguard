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
                    verdictSection
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Quick check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive, action: clear)
                        .disabled(!hasAnyInput)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Next") { focusNext() }
                    Spacer()
                    Button("Done") { focused = nil }
                }
            }
            .onAppear { platform = state.settings.defaultPlatform }
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
                // displayed fare is gross or net changes the answer by a fifth,
                // and it is the single easiest thing to have configured wrong.
                Text(state.settings.fareIsNet(for: platform) ? "already net" : "before commission")
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

    // MARK: - Verdict

    @ViewBuilder
    private var verdictSection: some View {
        if let economics {
            VerdictCardView(economics: economics)
                .animation(.snappy, value: economics.net)

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
        // Refusing to guess a zero-km pickup is a deliberate rule shared with
        // the parser: a missing deadhead leg flatters the offer exactly when
        // the driver needs the truth.
        return "Add both legs — pickup and trip distance — so the fuel and wear can be charged on every kilometre you actually drive."
    }

    // MARK: - Actions

    private func log(_ decision: HistoryEntry.Decision) {
        guard let economics else { return }
        state.log(economics, source: .manual, decision: decision)
        withAnimation { justLogged = true }
        focused = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { justLogged = false }
            clear()
        }
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

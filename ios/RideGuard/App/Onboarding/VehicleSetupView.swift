import SwiftUI
import RideGuardCore

/// The two numbers that make the whole app work: what the car drinks and what
/// that costs. Used both in onboarding and from Settings, so it takes a
/// binding and owns no state of its own.
struct VehicleSetupView: View {
    @Binding var vehicle: VehicleProfile

    /// Optional intro rendered as the Form's first section.
    ///
    /// Onboarding needs a heading above these fields. Wrapping this view in the
    /// onboarding scaffold's `ScrollView` to get one put a `Form` (itself a
    /// `List`) inside a `ScrollView` inside a paged `TabView` — three nested
    /// scroll containers, which is why keyboard avoidance never lifted a field
    /// here and the page gesture fought every drag. Passing the heading IN
    /// keeps exactly one scroll view on screen.
    var header: AnyView?

    /// Markets where Bolt and Uber both run and this app makes sense. Free
    /// text is still allowed underneath — a three-letter code is a three-letter
    /// code, and hard-coding a closed list would just lock somebody out.
    private let quickCurrencies = ["RON", "EUR", "PLN", "HUF", "BGN", "MDL", "UAH", "GBP"]

    var body: some View {
        Form {
            if let header {
                Section {
                    header.listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
                .listRowBackground(Color.clear)
            }

            Section("Car") {
                BufferedTextField("My car", text: $vehicle.label)
                Picker("Fuel", selection: $vehicle.fuelType) {
                    ForEach(FuelType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }

            Section {
                DecimalTextField(
                    title: "Consumption",
                    value: $vehicle.consumptionPer100km,
                    unit: vehicle.fuelType.consumptionLabel
                )
                DecimalTextField(
                    title: "Price per \(vehicle.fuelType.unitLabel)",
                    value: $vehicle.energyPrice,
                    unit: "\(vehicle.currency)/\(vehicle.fuelType.unitLabel)"
                )
            } header: {
                Text("Energy")
            } footer: {
                // The brochure figure is always optimistic, and city driving
                // with a passenger and the air conditioning on is the opposite
                // of the test cycle. A wrong number here biases every verdict.
                Text("Use your real-world figure from the trip computer, not the manufacturer's. City work with a passenger burns more than the brochure claims.")
            }

            Section {
                BufferedTextField("RON", text: $vehicle.currency)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickCurrencies, id: \.self) { code in
                            Button(code) { vehicle.currency = code }
                                .buttonStyle(.bordered)
                                .tint(vehicle.currency == code ? .accentColor : .secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Currency")
            }

            Section {
                LabeledContent {
                    Text("\(NumberParsing.formatRate(vehicle.totalCostPerKm)) \(vehicle.currency)/km")
                        .font(.body.weight(.semibold).monospacedDigit())
                } label: {
                    Text("Every kilometre costs you").font(.body.weight(.semibold))
                }
                if !vehicle.isPlausible {
                    Label("Those numbers do not look right — check the consumption and price.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("What this works out to")
            } footer: {
                // Stating both halves here because they are the two modelling
                // decisions that make RideGuard disagree with the driver app's
                // own maths — and the second one is the one drivers challenge.
                Text("Charged on every kilometre the car moves, including driving to the passenger, which no platform pays you for.\n\nFuel only. Tyres, servicing and depreciation are real, but a number invented at a petrol station would sit in every verdict looking just as solid as the two figures you actually know.")
            }
        }
        // Exactly one Done button for the whole screen, plus flick-to-dismiss
        // as an independent second way out.
        .keyboardDoneBar()
        .scrollDismissesKeyboard(.interactively)
    }
}

/// A text field over a `Double` that accepts whatever the driver's keyboard
/// produces.
///
/// `TextField(value:format:)` would bind to the device locale, so a phone set
/// to English would reject "17,50" — which is exactly what a Romanian keyboard
/// types and exactly what Bolt renders. Routing through `NumberParsing` means
/// the app accepts both conventions everywhere, the same way it does when
/// reading a screenshot.
struct DecimalTextField: View {
    let title: String
    @Binding var value: Double
    var unit: String?

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .focused($focused)
                .frame(maxWidth: 110)
                // Stable handle for the UI tests, which are the only thing that
                // catches a keyboard this app cannot dismiss.
                .accessibilityIdentifier("decimal.\(title)")
            if let unit {
                Text(unit)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        // NB: the Done button is NOT here. A keyboard toolbar declared on a
        // field contributes to the whole screen's accessory view, so one per
        // field renders one Done button per field. It lives once per screen —
        // see `View.keyboardDoneBar()`.
        //
        // The field is 110 pt at the trailing edge of a full-width row, so most
        // of what looks tappable was not. Now the whole row focuses it.
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        // Only ever re-seed from the outside while the driver is not typing.
        // Inside a Form these rows get recycled, and the old unconditional
        // `onAppear` could wipe a half-typed number.
        .onAppear { if !focused { text = Self.display(value) } }
        .onChange(of: value) { new in
            if !focused { text = Self.display(new) }
        }
        .onChange(of: text) { new in
            if let parsed = NumberParsing.parseDecimal(new) { value = parsed }
            // An empty field is mid-edit, not zero: leaving `value` alone means
            // clearing the field to retype does not briefly write a 0 that a
            // live verdict would react to.
        }
        .onChange(of: focused) { isFocused in
            // Re-normalise on blur so "7," or "007" settles to something sane.
            if !isFocused { text = Self.display(value) }
        }
    }

    /// Seeds the field with the separator this driver's keyboard actually
    /// produces.
    ///
    /// `formatRate` always emits a dot. On a Romanian phone the decimal pad
    /// emits a comma, so seeding "6.5" and typing one more digit gave "6.5,3" —
    /// which `parseDecimal` reads, by its documented "last separator wins" rule,
    /// as **65.3**. A ten-times-wrong fuel price silently poisons every verdict
    /// the app gives, which makes this the most expensive typo in the app.
    private static func display(_ value: Double) -> String {
        let formatted = NumberParsing.formatRate(value)
        guard let separator = Locale.current.decimalSeparator, separator != "." else {
            return formatted
        }
        return formatted.replacingOccurrences(of: ".", with: separator)
    }
}

/// A plain text field that does not write to the model on every keystroke.
///
/// `vehicle.label` and `vehicle.currency` were bound straight through to
/// `AppState.settings`, whose `didSet` saves to disk and republishes. Every
/// single character therefore triggered a file write and a rebuild of the whole
/// Form — and because the currency is interpolated into four sibling rows'
/// unit strings, those rebuilt too. That is the classic SwiftUI recipe for
/// dropped keystrokes and a caret that jumps, and it is what "some inputs do
/// not receive input" was.
///
/// The buffer is local; the model is written on blur, when the driver has
/// stopped typing.
struct BufferedTextField: View {
    private let placeholder: String
    @Binding private var text: String

    @State private var buffer: String = ""
    @FocusState private var focused: Bool

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        TextField(placeholder, text: $buffer)
            .focused($focused)
            .onAppear { if !focused { buffer = text } }
            .onChange(of: text) { new in
                // Kept in step when something else changes it — the currency
                // quick-pick buttons sitting directly under this field do.
                if !focused, new != buffer { buffer = new }
            }
            .onChange(of: focused) { isFocused in
                if !isFocused { commit() }
            }
            .onSubmit(commit)
    }

    private func commit() {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != text { text = trimmed }
        buffer = trimmed
    }
}

private struct VehicleSetupPreview: View {
    @State private var vehicle = VehicleProfile.defaultRO
    var body: some View { NavigationStack { VehicleSetupView(vehicle: $vehicle) } }
}

#Preview {
    VehicleSetupPreview()
}

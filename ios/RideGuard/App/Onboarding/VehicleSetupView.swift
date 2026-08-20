import SwiftUI
import RideGuardCore

/// The two numbers that make the whole app work: what the car drinks and what
/// that costs. Used both in onboarding and from Settings, so it takes a
/// binding and owns no state of its own.
struct VehicleSetupView: View {
    @Binding var vehicle: VehicleProfile

    /// Markets where Bolt and Uber both run and this app makes sense. Free
    /// text is still allowed underneath — a three-letter code is a three-letter
    /// code, and hard-coding a closed list would just lock somebody out.
    private let quickCurrencies = ["RON", "EUR", "PLN", "HUF", "BGN", "MDL", "UAH", "GBP"]

    var body: some View {
        Form {
            Section("Car") {
                TextField("My car", text: $vehicle.label)
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
                TextField("RON", text: $vehicle.currency)
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
            if let unit {
                Text(unit)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { text = NumberParsing.formatRate(value) }
        .onChange(of: text) { new in
            if let parsed = NumberParsing.parseDecimal(new) { value = parsed }
            // An empty field is mid-edit, not zero: leaving `value` alone means
            // clearing the field to retype does not briefly write a 0 that a
            // live verdict would react to.
        }
        .onChange(of: focused) { isFocused in
            // Re-normalise on blur so "7," or "007" settles to something sane.
            if !isFocused { text = NumberParsing.formatRate(value) }
        }
    }
}

private struct VehicleSetupPreview: View {
    @State private var vehicle = VehicleProfile.defaultRO
    var body: some View { NavigationStack { VehicleSetupView(vehicle: $vehicle) } }
}

#Preview {
    VehicleSetupPreview()
}

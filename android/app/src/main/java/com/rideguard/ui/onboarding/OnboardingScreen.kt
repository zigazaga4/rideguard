package com.rideguard.ui.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rideguard.R
import com.rideguard.data.SettingsRepository
import com.rideguard.domain.model.DriverThresholds
import com.rideguard.domain.model.FuelType
import com.rideguard.domain.model.VehicleProfile
import com.rideguard.domain.parse.NumberParsing
import com.rideguard.ui.ChipRow
import com.rideguard.ui.NumberField
import com.rideguard.ui.PrimaryButton
import com.rideguard.ui.RgColors
import com.rideguard.ui.SecondaryButton
import com.rideguard.ui.TextField
import kotlinx.coroutines.launch

/**
 * First run. Four short steps, then permissions.
 *
 * Kept deliberately brief because a driver setting this up is very often
 * sitting in a car park between rides, not at a desk. Anything not strictly
 * needed to make the maths correct has a sensible default and lives in
 * Settings instead.
 */
@Composable
fun OnboardingScreen(
    settings: SettingsRepository,
    onFinished: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var step by remember { mutableStateOf(0) }

    var label by remember { mutableStateOf("My car") }
    var fuelType by remember { mutableStateOf(FuelType.PETROL) }
    var consumption by remember { mutableStateOf("7.0") }
    var energyPrice by remember { mutableStateOf("7.5") }
    var currency by remember { mutableStateOf("RON") }
    var wear by remember { mutableStateOf("0.35") }

    var minNetPerKm by remember { mutableStateOf("1.5") }
    var minNetPerHour by remember { mutableStateOf("40") }
    var maxDeadhead by remember { mutableStateOf("0.8") }

    fun num(s: String, fallback: Double) = NumberParsing.parseDecimal(s) ?: fallback

    val vehicle = VehicleProfile(
        label = label.ifBlank { "My car" },
        fuelType = fuelType,
        consumptionPer100km = num(consumption, 7.0),
        energyPrice = num(energyPrice, 7.5),
        currency = currency.ifBlank { "RON" },
        wearCostPerKm = num(wear, 0.35),
    )

    Column(
        Modifier
            .fillMaxSize()
            .background(RgColors.Background)
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        StepIndicator(step = step, total = 4)

        when (step) {
            0 -> WelcomeStep()

            1 -> CarStep(
                label = label, onLabel = { label = it },
                fuelType = fuelType, onFuelType = { fuelType = it },
                consumption = consumption, onConsumption = { consumption = it },
                energyPrice = energyPrice, onEnergyPrice = { energyPrice = it },
                currency = currency, onCurrency = { currency = it },
                vehicle = vehicle,
            )

            2 -> WearStep(
                wear = wear,
                onWear = { wear = it },
                vehicle = vehicle,
            )

            3 -> TargetsStep(
                minNetPerKm = minNetPerKm, onMinNetPerKm = { minNetPerKm = it },
                minNetPerHour = minNetPerHour, onMinNetPerHour = { minNetPerHour = it },
                maxDeadhead = maxDeadhead, onMaxDeadhead = { maxDeadhead = it },
                currency = vehicle.currency,
            )
        }

        Spacer(Modifier.height(4.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (step > 0) {
                SecondaryButton("Back") { step-- }
            }
            PrimaryButton(
                label = if (step == 3) "Finish setup" else "Continue",
                modifier = Modifier.weight(1f),
            ) {
                if (step < 3) {
                    step++
                } else {
                    scope.launch {
                        settings.saveVehicle(vehicle)
                        settings.saveThresholds(
                            DriverThresholds(
                                minNetPerHour = num(minNetPerHour, 40.0),
                                minNetPerKm = num(minNetPerKm, 1.5),
                                maxDeadheadRatio = num(maxDeadhead, 0.8),
                            ),
                        )
                        settings.setOnboarded(true)
                        onFinished()
                    }
                }
            }
        }
    }
}

@Composable
private fun StepIndicator(step: Int, total: Int) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        repeat(total) { i ->
            Box(
                Modifier
                    .weight(1f)
                    .height(3.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(if (i <= step) RgColors.Good else RgColors.SurfaceHigh),
            )
        }
    }
}

@Composable
private fun WelcomeStep() {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Title(stringResource(R.string.onboarding_welcome_title))
        Body(stringResource(R.string.onboarding_welcome_body))
    }
}

@Composable
private fun CarStep(
    label: String, onLabel: (String) -> Unit,
    fuelType: FuelType, onFuelType: (FuelType) -> Unit,
    consumption: String, onConsumption: (String) -> Unit,
    energyPrice: String, onEnergyPrice: (String) -> Unit,
    currency: String, onCurrency: (String) -> Unit,
    vehicle: VehicleProfile,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Title(stringResource(R.string.onboarding_car_title))
        Body(stringResource(R.string.onboarding_car_body))

        TextField("Car name", label, onLabel)

        ChipRow(
            options = FuelType.entries,
            selected = fuelType,
            onSelect = onFuelType,
            label = { if (it == FuelType.ELECTRIC) "EV" else it.displayName.take(6) },
        )

        NumberField(
            label = "Consumption",
            value = consumption,
            onValueChange = onConsumption,
            suffix = vehicle.fuelType.consumptionLabel,
            helper = if (fuelType.isElectric) {
                "Real consumption including city traffic — usually higher than the brochure figure."
            } else {
                "Your real-world figure. City driving with a passenger is thirstier than the manufacturer's number."
            },
        )

        NumberField(
            label = if (fuelType.isElectric) "Electricity price" else "Fuel price",
            value = energyPrice,
            onValueChange = onEnergyPrice,
            suffix = "$currency / ${vehicle.fuelType.unitLabel}",
            helper = "What you actually pay at your usual station or charger.",
        )

        TextField("Currency", currency, onCurrency)

        CostPreview(vehicle, showWear = false)
    }
}

@Composable
private fun WearStep(wear: String, onWear: (String) -> Unit, vehicle: VehicleProfile) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Title(stringResource(R.string.onboarding_wear_title))
        Body(stringResource(R.string.onboarding_wear_body))

        NumberField(
            label = "Wear and tear",
            value = wear,
            onValueChange = onWear,
            suffix = "${vehicle.currency} / km",
            helper = "Tyres, servicing, brakes, depreciation. If you are unsure, leave the default — it is deliberately conservative.",
        )

        CostPreview(vehicle, showWear = true)
    }
}

@Composable
private fun TargetsStep(
    minNetPerKm: String, onMinNetPerKm: (String) -> Unit,
    minNetPerHour: String, onMinNetPerHour: (String) -> Unit,
    maxDeadhead: String, onMaxDeadhead: (String) -> Unit,
    currency: String,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Title(stringResource(R.string.onboarding_targets_title))
        Body(stringResource(R.string.onboarding_targets_body))

        NumberField("Minimum per km", minNetPerKm, onMinNetPerKm, suffix = "$currency / km")
        NumberField("Minimum per hour", minNetPerHour, onMinNetPerHour, suffix = "$currency / h")
        NumberField(
            label = "Maximum pickup ratio",
            value = maxDeadhead,
            onValueChange = onMaxDeadhead,
            suffix = "×",
            helper = "Pickup distance divided by trip distance. At 0.8 you are driving 8 km to collect for every 10 km paid — past that, most offers are not worth taking.",
        )
    }
}

/**
 * Turns the abstract inputs into the one number that makes them concrete:
 * what a single kilometre costs. Watching this move as they type is what
 * makes drivers take the wear figure seriously.
 */
@Composable
private fun CostPreview(vehicle: VehicleProfile, showWear: Boolean) {
    val perKm = if (showWear) vehicle.totalCostPerKm else vehicle.energyCostPerKm
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(RgColors.Surface)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Text(
            text = if (showWear) "Every kilometre costs you" else "Fuel alone costs you",
            color = RgColors.Secondary,
            fontSize = 11.sp,
        )
        Text(
            text = NumberParsing.formatMoney(perKm, vehicle.currency),
            color = RgColors.Good,
            fontSize = 26.sp,
            fontWeight = FontWeight.Black,
        )
        Text(
            text = "A 10 km ride costs " +
                NumberParsing.formatMoney(perKm * 10, vehicle.currency) +
                " before you earn anything.",
            color = RgColors.Secondary,
            fontSize = 11.sp,
            lineHeight = 15.sp,
        )
    }
}

@Composable
private fun Title(text: String) {
    Text(text, color = RgColors.Primary, fontSize = 23.sp, fontWeight = FontWeight.Black, lineHeight = 29.sp)
}

@Composable
private fun Body(text: String) {
    Text(text, color = RgColors.Secondary, fontSize = 13.sp, lineHeight = 19.sp)
}

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
import com.rideguard.domain.model.FuelType
import com.rideguard.domain.model.VehicleProfile
import com.rideguard.domain.parse.NumberParsing
import com.rideguard.ui.ChipRow
import com.rideguard.ui.NumberField
import com.rideguard.ui.PrimaryButton
import com.rideguard.ui.RgColors
import com.rideguard.ui.SecondaryButton
import kotlinx.coroutines.launch

/** Welcome, then the car. Nothing else earns a step. */
private const val LAST_STEP = 1

/**
 * First run: what the app does, and the two numbers it cannot work without.
 *
 * Every extra question here is a driver who never finishes setup — this is
 * done in a car park between rides, not at a desk. Targets are deliberately
 * absent: a driver who has not yet seen a single verdict has no basis to
 * invent one, so asking him to produce three numbers before his first ride
 * gets guesses that then look exactly as authoritative as the figures he
 * actually knows. The defaults are honest, and Settings is where they get
 * tightened once a week of driving has given him something to tighten them
 * against.
 */
@Composable
fun OnboardingScreen(
    settings: SettingsRepository,
    onFinished: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var step by remember { mutableStateOf(0) }

    var fuelType by remember { mutableStateOf(FuelType.PETROL) }
    var consumption by remember { mutableStateOf("7.0") }
    var energyPrice by remember { mutableStateOf("7.5") }

    fun num(s: String, fallback: Double) = NumberParsing.parseDecimal(s) ?: fallback

    // Name and currency keep their defaults and stay editable in Settings.
    // Neither moves a single figure in a verdict, so neither is worth a field
    // on the one screen a driver has to get through before the app is useful.
    val vehicle = VehicleProfile(
        fuelType = fuelType,
        consumptionPer100km = num(consumption, 7.0),
        energyPrice = num(energyPrice, 7.5),
    )

    Column(
        Modifier
            .fillMaxSize()
            .background(RgColors.Background)
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        StepIndicator(step = step, total = LAST_STEP + 1)

        when (step) {
            0 -> WelcomeStep()

            1 -> CarStep(
                fuelType = fuelType, onFuelType = { fuelType = it },
                consumption = consumption, onConsumption = { consumption = it },
                energyPrice = energyPrice, onEnergyPrice = { energyPrice = it },
                vehicle = vehicle,
            )
        }

        Spacer(Modifier.height(4.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (step > 0) {
                SecondaryButton("Back") { step-- }
            }
            PrimaryButton(
                label = if (step == LAST_STEP) "Finish setup" else "Continue",
                modifier = Modifier.weight(1f),
            ) {
                if (step < LAST_STEP) {
                    step++
                } else {
                    scope.launch {
                        settings.saveVehicle(vehicle)
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

        // The accessibility grant is the one thing worth explaining before
        // Android asks for it. A driver who does not understand why a ride app
        // wants an accessibility service will refuse it, and refusing it leaves
        // him with an app that does nothing at all.
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(RgColors.Surface)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                text = stringResource(R.string.onboarding_permissions_title),
                color = RgColors.Primary,
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold,
            )
            Body(stringResource(R.string.onboarding_permissions_body))
        }
    }
}

@Composable
private fun CarStep(
    fuelType: FuelType, onFuelType: (FuelType) -> Unit,
    consumption: String, onConsumption: (String) -> Unit,
    energyPrice: String, onEnergyPrice: (String) -> Unit,
    vehicle: VehicleProfile,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Title(stringResource(R.string.onboarding_car_title))
        Body(stringResource(R.string.onboarding_car_body))

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
            suffix = "${vehicle.currency} / ${vehicle.fuelType.unitLabel}",
            helper = "What you actually pay at your usual station or charger.",
        )

        CostPreview(vehicle)
    }
}

/**
 * Turns two abstract inputs into the one number that makes them concrete:
 * what a single kilometre costs. Watching this figure move as he types is what
 * makes a driver bother to correct the defaults instead of tapping through.
 */
@Composable
private fun CostPreview(vehicle: VehicleProfile) {
    val perKm = vehicle.totalCostPerKm
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(RgColors.Surface)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Text(
            text = "Every kilometre costs you",
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

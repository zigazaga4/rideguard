package com.rideguard.ui.settings

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rideguard.BuildConfig
import com.rideguard.Permissions
import com.rideguard.data.SettingsRepository
import com.rideguard.domain.model.DriverThresholds
import com.rideguard.domain.model.FuelType
import com.rideguard.domain.model.Platform
import com.rideguard.domain.model.VehicleProfile
import com.rideguard.domain.parse.NumberParsing
import com.rideguard.ui.ChipRow
import com.rideguard.ui.NumberField
import com.rideguard.ui.RgColors
import com.rideguard.ui.SectionHeader
import com.rideguard.ui.SettingSwitch
import com.rideguard.ui.StepCard
import com.rideguard.ui.TextField
import kotlinx.coroutines.launch

/**
 * Home screen once onboarding is done.
 *
 * Setup status lives at the top on purpose: the most common support question
 * for an app like this is "it stopped working", and the answer is almost
 * always that the OEM battery manager killed the service or the accessibility
 * toggle got reset by a system update. Putting live status first makes that
 * self-diagnosing.
 */
@Composable
fun SettingsScreen(
    settings: SettingsRepository,
    onReplayOnboarding: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    val vehicle by settings.vehicle.collectAsState(initial = VehicleProfile.DEFAULT_RO)
    val thresholds by settings.thresholds.collectAsState(initial = DriverThresholds())
    val recordMode by settings.recordModeEnabled.collectAsState(initial = false)

    // Permission state is read fresh on every recomposition because the user
    // leaves the app to change it and comes back — there is no callback.
    var refreshTick by remember { mutableStateOf(0) }
    val a11yOn = remember(refreshTick) {
        Permissions.isAccessibilityServiceEnabled(context, Permissions.ACCESSIBILITY_SERVICE_CLASS)
    }
    val overlayOn = remember(refreshTick) { Permissions.canDrawOverlays(context) }
    val batteryOk = remember(refreshTick) { Permissions.isIgnoringBatteryOptimizations(context) }

    LaunchedEffect(Unit) { refreshTick++ }

    Column(
        Modifier
            .fillMaxSize()
            .background(RgColors.Background)
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("RideGuard", color = RgColors.Primary, fontSize = 26.sp, fontWeight = FontWeight.Black)

        // ------------------------------------------------------------ setup
        SectionHeader("Setup", "All three must be green for the HUD to appear.")

        if (BuildConfig.USE_ACCESSIBILITY) {
            StepCard(
                title = "Offer reader",
                body = "Lets RideGuard read the offer card in Bolt and Uber. Nothing leaves your phone. " +
                    "Find RideGuard under Installed apps or Downloaded apps and switch it on.",
                actionLabel = "Open accessibility settings",
                done = a11yOn,
                onAction = {
                    context.startActivity(Permissions.accessibilitySettingsIntent())
                    refreshTick++
                },
            )
        } else {
            StepCard(
                title = "Draw over other apps",
                body = "Lets the HUD float above Bolt and Uber.",
                actionLabel = "Grant overlay permission",
                done = overlayOn,
                onAction = {
                    context.startActivity(Permissions.overlaySettingsIntent(context))
                    refreshTick++
                },
            )
        }

        StepCard(
            title = "Battery exemption",
            body = "Android will kill the reader mid-shift without this.",
            actionLabel = "Allow background running",
            done = batteryOk,
            onAction = {
                context.startActivity(Permissions.batteryOptimizationIntent(context))
                refreshTick++
            },
        )

        Permissions.oemAutostartHint()?.let { hint ->
            OemWarning(hint) { context.openUrl(Permissions.DONT_KILL_MY_APP_URL) }
        }

        // -------------------------------------------------------------- car
        SectionHeader("Your car", "Changing these re-evaluates live offers immediately.")
        VehicleEditor(vehicle) { updated -> scope.launch { settings.saveVehicle(updated) } }

        // -------------------------------------------------------- thresholds
        SectionHeader("Targets", "What makes an offer green, amber or red.")
        ThresholdEditor(thresholds, vehicle.currency) { updated ->
            scope.launch { settings.saveThresholds(updated) }
        }

        // --------------------------------------------------------- platforms
        SectionHeader(
            "Platforms",
            "Verify these against a real weekly payout statement — whether the card shows gross or net " +
                "varies by country, and getting it wrong skews every number by the commission rate.",
        )
        Platform.entries.filter { it != Platform.UNKNOWN }.forEach { platform ->
            PlatformEditor(platform, settings)
        }

        // ------------------------------------------------------------- tools
        SectionHeader("Developer", "For tuning the parser against real offers.")
        SettingSwitch(
            title = "Record offers to disk",
            subtitle = "Saves every offer card as a JSON fixture. Run one shift with this on, " +
                "then the parser can be tuned on a laptop against real data instead of guesswork.",
            checked = recordMode,
            onCheckedChange = { scope.launch { settings.setRecordMode(it) } },
        )

        Box(Modifier.height(8.dp))
        com.rideguard.ui.SecondaryButton("Run setup again", onClick = onReplayOnboarding)
        Box(Modifier.height(24.dp))
    }
}

@Composable
private fun VehicleEditor(vehicle: VehicleProfile, onChange: (VehicleProfile) -> Unit) {
    var consumption by remember(vehicle) { mutableStateOf(fmt(vehicle.consumptionPer100km)) }
    var price by remember(vehicle) { mutableStateOf(fmt(vehicle.energyPrice)) }
    var wear by remember(vehicle) { mutableStateOf(fmt(vehicle.wearCostPerKm)) }
    var label by remember(vehicle) { mutableStateOf(vehicle.label) }

    fun push(next: VehicleProfile) = onChange(next)

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        TextField("Car name", label, {
            label = it
            push(vehicle.copy(label = it))
        })

        ChipRow(
            options = FuelType.entries,
            selected = vehicle.fuelType,
            onSelect = { push(vehicle.copy(fuelType = it)) },
            label = { if (it == FuelType.ELECTRIC) "EV" else it.displayName.take(6) },
        )

        NumberField(
            label = "Consumption",
            value = consumption,
            onValueChange = {
                consumption = it
                NumberParsing.parseDecimal(it)?.let { v -> push(vehicle.copy(consumptionPer100km = v)) }
            },
            suffix = vehicle.fuelType.consumptionLabel,
        )

        NumberField(
            label = if (vehicle.fuelType.isElectric) "Electricity price" else "Fuel price",
            value = price,
            onValueChange = {
                price = it
                NumberParsing.parseDecimal(it)?.let { v -> push(vehicle.copy(energyPrice = v)) }
            },
            suffix = "${vehicle.currency} / ${vehicle.fuelType.unitLabel}",
        )

        NumberField(
            label = "Wear and tear",
            value = wear,
            onValueChange = {
                wear = it
                NumberParsing.parseDecimal(it)?.let { v -> push(vehicle.copy(wearCostPerKm = v)) }
            },
            suffix = "${vehicle.currency} / km",
        )

        Box(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(RgColors.Surface)
                .padding(14.dp),
        ) {
            Text(
                text = "Every kilometre costs you " +
                    NumberParsing.formatMoney(vehicle.totalCostPerKm, vehicle.currency) +
                    "  (fuel " + NumberParsing.formatRate(vehicle.energyCostPerKm) +
                    " + wear " + NumberParsing.formatRate(vehicle.wearCostPerKm) + ")",
                color = RgColors.Secondary,
                fontSize = 12.sp,
                lineHeight = 17.sp,
            )
        }
    }
}

@Composable
private fun ThresholdEditor(
    thresholds: DriverThresholds,
    currency: String,
    onChange: (DriverThresholds) -> Unit,
) {
    var perKm by remember(thresholds) { mutableStateOf(fmt(thresholds.minNetPerKm)) }
    var perHour by remember(thresholds) { mutableStateOf(fmt(thresholds.minNetPerHour)) }
    var deadhead by remember(thresholds) { mutableStateOf(fmt(thresholds.maxDeadheadRatio)) }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        NumberField("Minimum per km", perKm, {
            perKm = it
            NumberParsing.parseDecimal(it)?.let { v -> onChange(thresholds.copy(minNetPerKm = v)) }
        }, suffix = "$currency / km")

        NumberField("Minimum per hour", perHour, {
            perHour = it
            NumberParsing.parseDecimal(it)?.let { v -> onChange(thresholds.copy(minNetPerHour = v)) }
        }, suffix = "$currency / h")

        NumberField("Maximum pickup ratio", deadhead, {
            deadhead = it
            NumberParsing.parseDecimal(it)?.let { v -> onChange(thresholds.copy(maxDeadheadRatio = v)) }
        }, suffix = "×")
    }
}

@Composable
private fun PlatformEditor(platform: Platform, settings: SettingsRepository) {
    val scope = rememberCoroutineScope()
    val pipeline by settings.settings.collectAsState(initial = null)

    val commission = pipeline?.commissionFor(platform) ?: platform.defaultCommissionRate
    val isNet = pipeline?.fareIsNetFor(platform) ?: platform.fareShownIsNetByDefault

    var commissionText by remember(commission) { mutableStateOf(fmt(commission * 100)) }

    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(RgColors.Surface)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(platform.displayName, color = RgColors.Primary, fontSize = 15.sp, fontWeight = FontWeight.Bold)

        NumberField(
            label = "Commission",
            value = commissionText,
            onValueChange = {
                commissionText = it
                NumberParsing.parseDecimal(it)?.let { v ->
                    scope.launch { settings.savePlatformConfig(platform, v / 100.0, isNet) }
                }
            },
            suffix = "%",
        )

        SettingSwitch(
            title = "Fare shown is already net",
            subtitle = if (isNet) {
                "The number on the card is what you keep before running costs."
            } else {
                "The number on the card is gross; commission is taken off it."
            },
            checked = isNet,
            onCheckedChange = { next ->
                scope.launch { settings.savePlatformConfig(platform, commission, next) }
            },
        )
    }
}

@Composable
private fun OemWarning(hint: String, onOpenGuide: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(RgColors.Marginal.copy(alpha = 0.13f))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            "Your phone needs one extra step",
            color = RgColors.Marginal,
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
        )
        Text(hint, color = RgColors.Secondary, fontSize = 12.sp, lineHeight = 17.sp)
        com.rideguard.ui.SecondaryButton("Open the guide", onClick = onOpenGuide)
    }
}

private fun fmt(v: Double): String = NumberParsing.formatRate(v, 2)

private fun Context.openUrl(url: String) {
    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

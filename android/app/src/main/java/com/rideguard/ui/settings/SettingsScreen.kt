package com.rideguard.ui.settings

import android.content.Context
import android.content.Intent
import android.net.Uri
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
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
import com.rideguard.domain.model.VehicleProfile
import com.rideguard.domain.parse.NumberParsing
import com.rideguard.ui.ChipRow
import com.rideguard.ui.NumberField
import com.rideguard.ui.RgColors
import com.rideguard.ui.SectionHeader
import com.rideguard.ui.SettingSwitch
import com.rideguard.ui.StepCard
import com.rideguard.ui.TextField
import com.rideguard.ui.rememberResumeTick
import kotlinx.coroutines.launch

/**
 * Home screen once onboarding is done.
 *
 * Setup status lives at the top on purpose: the most common support question
 * for an app like this is "it stopped working", and the answer is almost
 * always that the OEM battery manager killed the service or the accessibility
 * toggle got reset by a system update. Putting live status first makes that
 * self-diagnosing.
 *
 * There is no commission or gross/net control here any more, and that is a
 * correctness decision rather than a tidying one. Both Romanian apps print the
 * driver's net take on the card — Bolt says so outright, Uber labels it
 * "Câștig net" — so the defaults are right, and every knob that can be turned
 * wrong is a way for a driver to silently break every number the HUD shows him.
 */
@Composable
fun SettingsScreen(
    settings: SettingsRepository,
    onReplayOnboarding: () -> Unit,
    onOpenUpdates: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    val vehicle by settings.vehicle.collectAsState(initial = VehicleProfile.DEFAULT_RO)
    val thresholds by settings.thresholds.collectAsState(initial = DriverThresholds())
    val recordMode by settings.recordModeEnabled.collectAsState(initial = false)

    var showDeveloper by rememberSaveable { mutableStateOf(false) }

    // Every one of these is granted on a system screen in another process, with
    // no callback and no broadcast. Coming back to the foreground IS the signal
    // — so they are re-read on every resume and never cached beyond it. See
    // [rememberResumeTick] for the stale-TODO bug this replaced.
    val resumeTick = rememberResumeTick()
    val a11yOn = remember(resumeTick) {
        Permissions.isAccessibilityServiceEnabled(context, Permissions.ACCESSIBILITY_SERVICE_CLASS)
    }
    val overlayOn = remember(resumeTick) { Permissions.canDrawOverlays(context) }
    val batteryOk = remember(resumeTick) { Permissions.isIgnoringBatteryOptimizations(context) }

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
        SectionHeader("Setup", "Both of these must say DONE before the HUD appears.")

        if (BuildConfig.USE_ACCESSIBILITY) {
            StepCard(
                title = "Offer reader",
                body = "Lets RideGuard read the offer card in Bolt and Uber. Nothing leaves your phone. " +
                    "Find RideGuard under Installed apps or Downloaded apps and switch it on.",
                actionLabel = "Open accessibility settings",
                done = a11yOn,
                onAction = {
                    context.startActivity(Permissions.accessibilitySettingsIntent())
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
            },
        )

        Permissions.oemAutostartHint()?.let { hint ->
            OemWarning(hint) { context.openUrl(Permissions.DONT_KILL_MY_APP_URL) }
        }

        // --------------------------------------------------------- hud size
        //
        // Deliberately an explicit mode rather than a gesture that is always
        // live. The HUD window is FLAG_NOT_TOUCHABLE during a shift so it can
        // never swallow a tap meant for Accept; this is the one moment it takes
        // touch, and it ends the moment the driver taps Done on the HUD itself.
        SectionHeader(
            "HUD size and position",
            "Drag it where you want it and pinch to resize. Bolt and Uber both use what you set here.",
        )
        com.rideguard.ui.SecondaryButton(
            label = "Place the HUD",
            onClick = { scope.launch { settings.setHudAdjustMode(true) } },
        )
        Text(
            text = if (BuildConfig.USE_ACCESSIBILITY) {
                "The offer reader has to be running. A sample card appears over whatever is on " +
                    "screen — drag, pinch, then tap Done on the card itself."
            } else {
                "Screen reading has to be running. A sample card appears over whatever is on " +
                    "screen — drag, pinch, then tap Done on the card itself."
            },
            color = RgColors.Secondary,
            fontSize = 11.sp,
            lineHeight = 15.sp,
        )

        // -------------------------------------------------------------- car
        SectionHeader("Your car", "Changing these re-evaluates live offers immediately.")
        VehicleEditor(vehicle) { updated -> scope.launch { settings.saveVehicle(updated) } }

        // -------------------------------------------------------- thresholds
        SectionHeader(
            "Targets",
            "What makes an offer green, amber or red over the offer card. The line under each " +
                "one says whether the number you typed can actually do that job.",
        )
        ThresholdEditor(thresholds, vehicle) { updated ->
            scope.launch { settings.saveThresholds(updated) }
        }

        // ----------------------------------------------------------- updates
        SectionHeader("Updates", "This build does not update itself.")
        com.rideguard.ui.SecondaryButton("Check for updates", onClick = onOpenUpdates)

        // ------------------------------------------------------------- tools
        //
        // Folded away because record mode writes a JSON fixture for every card
        // it sees. That is exactly what we want for one deliberate tuning shift
        // and exactly what we do not want left on by a driver who tapped a
        // switch to find out what it did.
        Box(Modifier.height(8.dp))
        com.rideguard.ui.SecondaryButton(
            label = if (showDeveloper) "Hide developer tools" else "Developer tools",
            onClick = { showDeveloper = !showDeveloper },
        )
        if (showDeveloper) {
            SettingSwitch(
                title = "Record offers to disk",
                subtitle = "Saves every offer card as a JSON fixture. Run one shift with this on, " +
                    "then the parser can be tuned on a laptop against real data instead of guesswork.",
                checked = recordMode,
                onCheckedChange = { scope.launch { settings.setRecordMode(it) } },
            )
        }

        Box(Modifier.height(8.dp))
        com.rideguard.ui.SecondaryButton("Run setup again", onClick = onReplayOnboarding)
        Box(Modifier.height(24.dp))
    }
}

@Composable
private fun VehicleEditor(vehicle: VehicleProfile, onChange: (VehicleProfile) -> Unit) {
    var consumption by remember(vehicle) { mutableStateOf(fmt(vehicle.consumptionPer100km)) }
    var price by remember(vehicle) { mutableStateOf(fmt(vehicle.energyPrice)) }
    var currency by remember(vehicle) { mutableStateOf(vehicle.currency) }
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

        // Blank is never pushed: an empty currency would propagate into every
        // formatted figure in the app the moment the field is cleared to retype.
        TextField("Currency", currency, {
            currency = it
            if (it.isNotBlank()) push(vehicle.copy(currency = it))
        })

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
                    ". A 10 km ride is " +
                    NumberParsing.formatMoney(vehicle.totalCostPerKm * 10, vehicle.currency) +
                    " gone before you earn anything.",
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
    vehicle: VehicleProfile,
    onChange: (DriverThresholds) -> Unit,
) {
    var perKm by remember(thresholds) { mutableStateOf(fmt(thresholds.minNetPerKm)) }
    var perHour by remember(thresholds) { mutableStateOf(fmt(thresholds.minNetPerHour)) }
    var deadhead by remember(thresholds) { mutableStateOf(fmt(thresholds.maxDeadheadRatio)) }

    val currency = vehicle.currency

    // Grouped tightly so each status line reads as belonging to the field above
    // it; the gap BETWEEN groups is what separates one target from the next.
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        TargetGroup {
            NumberField("Minimum per km", perKm, {
                perKm = it
                NumberParsing.parseDecimal(it)?.let { v -> onChange(thresholds.copy(minNetPerKm = v)) }
            }, suffix = "$currency / km")
            // Restated as what the CARD has to show, because that is the only
            // form the driver can check against a live offer: his target is
            // after fuel, the card is before it, and the gap is his own cost.
            TargetStatus(
                ok = thresholds.minNetPerKm > 0.0,
                text = if (thresholds.minNetPerKm > 0.0) {
                    "The card has to show at least " +
                        NumberParsing.formatRate(thresholds.minNetPerKm + vehicle.totalCostPerKm) +
                        " $currency/km"
                } else {
                    "At zero this can never be missed — nothing will turn red"
                },
            )
        }

        TargetGroup {
            NumberField("Minimum per hour", perHour, {
                perHour = it
                NumberParsing.parseDecimal(it)?.let { v -> onChange(thresholds.copy(minNetPerHour = v)) }
            }, suffix = "$currency / h")
            HourlyTargetStatus(thresholds)
        }

        TargetGroup {
            NumberField("Maximum pickup ratio", deadhead, {
                deadhead = it
                NumberParsing.parseDecimal(it)?.let { v -> onChange(thresholds.copy(maxDeadheadRatio = v)) }
            }, suffix = "×")
            TargetStatus(
                ok = thresholds.maxDeadheadRatio > 0.0 && thresholds.maxDeadheadRatio <= 1.0,
                text = when {
                    thresholds.maxDeadheadRatio <= 0.0 ->
                        "At zero every offer with a pickup leg is flagged"
                    thresholds.maxDeadheadRatio > 1.0 ->
                        "Above 1.0 you are driving further to collect than you are paid to carry"
                    else ->
                        "Flags a pickup longer than " +
                            NumberParsing.formatRate(thresholds.maxDeadheadRatio, 1) + "× the paid leg"
                },
            )
        }
    }
}

@Composable
private fun TargetGroup(content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) { content() }
}

/**
 * The two rate targets are not independent: dividing one by the other gives the
 * speed at which they agree, and either side of that speed only one of them is
 * ever the binding constraint. A driver who types 200/h next to 1.5/km has
 * written a target that cannot fire below 133 km/h, which in city traffic means
 * never — and a target that never fires is worse than no target, because he
 * believes it is protecting him.
 */
@Composable
private fun HourlyTargetStatus(thresholds: DriverThresholds) {
    val impliedKmh = thresholds.minNetPerKm
        .takeIf { it > 0.0 }
        ?.let { thresholds.minNetPerHour / it }
    val speed = impliedKmh?.let { NumberParsing.formatRate(it, 0) }

    TargetStatus(
        ok = thresholds.minNetPerHour > 0.0 && (impliedKmh == null || impliedKmh in 10.0..70.0),
        text = when {
            thresholds.minNetPerHour <= 0.0 -> "At zero this can never be missed — nothing will turn red"
            impliedKmh == null -> "Judging every offer on its own, since the per-km target is off"
            impliedKmh > 70.0 -> "Only bites above $speed km/h — in traffic, never"
            impliedKmh < 10.0 -> "Only bites below $speed km/h — your per-km target decides everything"
            else -> "Catches the slow jobs, below $speed km/h"
        },
    )
}

/**
 * The green/red the driver asked for, and it is careful about what it claims.
 *
 * Settings has no live offer in front of it, so colouring these against an
 * invented reference ride would be dressing a guess up as a measurement. What
 * it can say honestly is whether the number typed in is a bar at all — and that
 * catches the failure that actually happens, which is a target set somewhere it
 * can never be hit or never be missed.
 */
@Composable
private fun TargetStatus(ok: Boolean, text: String) {
    val tint = if (ok) RgColors.Good else RgColors.Bad
    Row(
        Modifier.padding(start = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(7.dp)
                .clip(RoundedCornerShape(50))
                .background(tint),
        )
        Spacer(Modifier.width(6.dp))
        Text(text, color = tint, fontSize = 11.sp, lineHeight = 15.sp)
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

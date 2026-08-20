package com.rideguard.overlay

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rideguard.domain.model.OfferEconomics
import com.rideguard.domain.model.Verdict
import com.rideguard.domain.parse.NumberParsing

/**
 * Design brief, and it is a narrow one: the driver has roughly ten to fifteen
 * seconds to accept, he is holding a phone in a car, and he will look at this
 * for about two seconds.
 *
 * So: one headline number, two rates, and a warning badge only when there is
 * something to warn about. Everything else is behind a tap. Adding "just one
 * more useful field" is exactly how a HUD like this becomes unreadable.
 */
private object HudColors {
    val Good = Color(0xFF16A34A)
    val Marginal = Color(0xFFF59E0B)
    val Bad = Color(0xFFDC2626)
    val Unknown = Color(0xFF64748B)

    /** Near-opaque so it stays legible over a bright map in daylight. */
    val Surface = Color(0xF2141619)
    val SurfaceSoft = Color(0xFF1E2228)
    val Primary = Color(0xFFF5F7FA)
    val Secondary = Color(0xFF9AA4B2)

    fun forVerdict(v: Verdict) = when (v) {
        Verdict.GOOD -> Good
        Verdict.MARGINAL -> Marginal
        Verdict.BAD -> Bad
        Verdict.UNKNOWN -> Unknown
    }
}

@Composable
fun OverlayHud(
    state: OverlayUiState,
    onDrag: (Float, Float) -> Unit,
    onToggleExpanded: () -> Unit,
    onDismiss: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    val economics = state.economics
    if (!state.visible || economics == null) return

    val accent = HudColors.forVerdict(economics.verdict)

    Box(
        modifier = Modifier
            .widthIn(min = 168.dp, max = 260.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(HudColors.Surface)
            .pointerInput(Unit) {
                detectDragGestures { change, dragAmount ->
                    change.consume()
                    onDrag(dragAmount.x, dragAmount.y)
                }
            }
            // Confidence below the threshold means we could not read the whole
            // card. Dimming is an honest signal — far better than rendering a
            // crisp number the driver would trust and act on.
            .alpha(if (economics.verdict == Verdict.UNKNOWN) 0.75f else 1f),
    ) {
        // IntrinsicSize.Min lets the verdict strip match whatever height the
        // content ends up being, instead of guessing a fixed dp that breaks
        // the moment a line wraps or the card expands.
        Row(Modifier.height(IntrinsicSize.Min)) {
            // Verdict strip — readable from the corner of the eye.
            Box(
                Modifier
                    .width(5.dp)
                    .fillMaxHeight()
                    .background(accent),
            )

            Column(
                modifier = Modifier
                    .padding(horizontal = 10.dp, vertical = 8.dp)
                    .clickable { onToggleExpanded() },
                verticalArrangement = Arrangement.spacedBy(1.dp),
            ) {
                EarningsPerKmRow(economics, accent)
                NetPerKmRow(economics)
                ContextRow(economics)

                AnimatedVisibility(visible = state.expanded) {
                    ExpandedDetail(
                        economics = economics,
                        onDismiss = onDismiss,
                        onOpenSettings = onOpenSettings,
                    )
                }
            }
        }
    }
}

/**
 * THE HEADLINE: what this ride pays per kilometre.
 *
 * Per-km is the right headline because it is the only figure that is directly
 * comparable between two offers of completely different sizes — a 6 lei hop
 * and a 120 lei airport run can be judged against each other instantly. A
 * total, by contrast, always flatters the longer ride.
 *
 * Commission is already removed here; running costs are not. The line
 * immediately below shows what the road takes back, so the gap between the two
 * numbers IS the cost of driving, made visible.
 */
@Composable
private fun EarningsPerKmRow(e: OfferEconomics, accent: Color) {
    Row(verticalAlignment = Alignment.Bottom) {
        Text(
            text = NumberParsing.formatFixed(e.earningsPerKm),
            color = accent,
            fontSize = 30.sp,
            lineHeight = 34.sp,
            fontWeight = FontWeight.Black,
        )
        Spacer(Modifier.width(3.dp))
        Text(
            text = "/km",
            color = HudColors.Secondary,
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 3.dp),
        )

        Spacer(Modifier.weight(1f))

        // Only shown when there is genuinely something to flag. A badge that
        // is always on screen stops being a warning and becomes decoration.
        val ratio = e.deadheadRatio
        if (ratio != null && ratio > 0.8) {
            WarningBadge("↩ ${NumberParsing.formatRate(ratio, 1)}×")
        }
    }
}

/**
 * The same number after fuel and wear — the one he actually keeps per km.
 *
 * Deliberately styled quieter than the headline but still fully legible: it is
 * the honest figure, and a driver who glances only at the top line should
 * still catch this one in peripheral vision when it goes negative.
 */
@Composable
private fun NetPerKmRow(e: OfferEconomics) {
    val negative = e.netPerKm < 0
    Row(verticalAlignment = Alignment.Bottom) {
        Text(
            text = "↓ ",
            color = HudColors.Secondary,
            fontSize = 12.sp,
        )
        Text(
            text = NumberParsing.formatFixed(e.netPerKm),
            color = if (negative) HudColors.Bad else HudColors.Primary,
            fontSize = 17.sp,
            lineHeight = 20.sp,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.width(3.dp))
        Text(
            text = "/km after fuel",
            color = HudColors.Secondary,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(bottom = 1.dp),
        )
    }
}

/** Everything else, in one quiet line: total kept, distance, hourly. */
@Composable
private fun ContextRow(e: OfferEconomics) {
    val perHour = e.netPerHour
    val text = buildString {
        append(NumberParsing.formatAuto(e.net))
        append(' ')
        append(e.currency)
        append("  ·  ")
        append(NumberParsing.formatRate(e.totalKm, 1))
        append(" km")
        if (perHour != null) {
            append("  ·  ")
            append(NumberParsing.formatAuto(perHour))
            append("/h")
        }
    }
    Text(
        text = text,
        color = HudColors.Secondary,
        fontSize = 11.sp,
        fontWeight = FontWeight.Medium,
        modifier = Modifier.padding(top = 2.dp),
    )
}

@Composable
private fun WarningBadge(label: String) {
    Box(
        Modifier
            .clip(RoundedCornerShape(5.dp))
            .background(HudColors.Bad.copy(alpha = 0.18f))
            .padding(horizontal = 5.dp, vertical = 2.dp),
    ) {
        Text(label, color = HudColors.Bad, fontSize = 10.sp, fontWeight = FontWeight.Bold)
    }
}

/** Behind a tap: where the money actually went. */
@Composable
private fun ExpandedDetail(
    economics: OfferEconomics,
    onDismiss: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    Column(
        modifier = Modifier.padding(top = 8.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Divider()
        DetailRow("Fare", NumberParsing.formatRate(economics.gross), economics.currency)
        if (economics.commission > 0.001) {
            DetailRow("Commission", "−" + NumberParsing.formatRate(economics.commission), economics.currency)
        }
        DetailRow("Fuel", "−" + NumberParsing.formatRate(economics.energyCost), economics.currency)
        DetailRow("Wear", "−" + NumberParsing.formatRate(economics.wearCost), economics.currency)
        Divider()
        DetailRow("Net", NumberParsing.formatRate(economics.net), economics.currency, strong = true)
        // Spells out the gap between the two headline lines.
        DetailRow(
            label = "Cost per km",
            value = "−" + NumberParsing.formatAuto(economics.costPerKm),
            currency = economics.currency,
        )

        economics.offer.productName?.let {
            Spacer(Modifier.height(2.dp))
            Text(it, color = HudColors.Secondary, fontSize = 10.sp)
        }

        economics.reasons.take(2).forEach { reason ->
            Text(
                text = reason,
                color = HudColors.Secondary,
                fontSize = 10.sp,
                lineHeight = 13.sp,
                modifier = Modifier.padding(top = 2.dp),
            )
        }

        Spacer(Modifier.height(6.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            SmallButton("Settings", Modifier.weight(1f), onOpenSettings)
            SmallButton("Hide", Modifier.weight(1f), onDismiss)
        }
    }
}

@Composable
private fun DetailRow(label: String, value: String, currency: String, strong: Boolean = false) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(
            label,
            color = if (strong) HudColors.Primary else HudColors.Secondary,
            fontSize = 11.sp,
            fontWeight = if (strong) FontWeight.Bold else FontWeight.Normal,
        )
        Spacer(Modifier.weight(1f))
        Text(
            "$value $currency",
            color = if (strong) HudColors.Primary else HudColors.Secondary,
            fontSize = 11.sp,
            fontWeight = if (strong) FontWeight.Bold else FontWeight.Medium,
        )
    }
}

@Composable
private fun Divider() {
    Box(
        Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(HudColors.SurfaceSoft),
    )
}

@Composable
private fun SmallButton(label: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(7.dp))
            .background(HudColors.SurfaceSoft)
            .clickable(onClick = onClick)
            .padding(vertical = 6.dp),
    ) {
        Text(
            text = label,
            color = HudColors.Primary,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

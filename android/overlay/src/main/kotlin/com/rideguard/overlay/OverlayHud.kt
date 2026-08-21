package com.rideguard.overlay

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rideguard.domain.model.OfferEconomics
import com.rideguard.domain.model.Verdict
import com.rideguard.domain.parse.NumberParsing
import kotlin.math.roundToInt

/**
 * Design brief, and it is a narrow one: the driver has roughly ten to fifteen
 * seconds to accept, he is holding a phone in a car, and he will look at this
 * for about two seconds.
 *
 * So: the verdict in one word, one headline number, one rate beneath it, one
 * quiet context line, and a warning badge only when there is something to warn
 * about. Each number carries a short caption saying what it is, because a bare
 * figure is only obvious to whoever wrote the app. Adding "just one more useful
 * field" beyond that is exactly how a HUD like this becomes unreadable.
 *
 * The verdict word is not decoration. It used to be carried entirely by colour,
 * which asks the driver to remember what amber means while merging into traffic
 * and tells a colour-blind driver nothing at all.
 *
 * Nothing here is interactive, and nothing here should become interactive. See
 * [OverlayHost] for why that is a safety property and not a preference.
 */
private object HudColors {
    val Good = Color(0xFF16A34A)
    val Marginal = Color(0xFFF59E0B)
    val Bad = Color(0xFFDC2626)
    val Unknown = Color(0xFF64748B)

    /** Near-opaque so it stays legible over a bright map in daylight. */
    val Surface = Color(0xF2141619)
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
    onDrag: (Float, Float) -> Unit = { _, _ -> },
    onPinch: (Float) -> Unit = {},
    onDone: () -> Unit = {},
) {
    val economics = state.economics
    if (!state.visible || economics == null) return

    // Size is applied by scaling the DENSITY rather than by scaling the drawn
    // result. A `graphicsLayer` scale would leave the window measuring its
    // original size and clip the HUD; changing density makes every dp and sp
    // grow together and lets the WRAP_CONTENT window re-measure around it, so
    // the driver gets a genuinely bigger window rather than a magnified one.
    val base = LocalDensity.current
    CompositionLocalProvider(
        LocalDensity provides Density(
            density = base.density * state.scale,
            fontScale = base.fontScale,
        ),
    ) {
        HudCard(state, economics, onDrag, onPinch, onDone)
    }
}

@Composable
private fun HudCard(
    state: OverlayUiState,
    economics: OfferEconomics,
    onDrag: (Float, Float) -> Unit,
    onPinch: (Float) -> Unit,
    onDone: () -> Unit,
) {
    val accent = HudColors.forVerdict(economics.verdict)

    Box(
        modifier = Modifier
            // Gestures exist ONLY while adjusting. Outside that the window is
            // FLAG_NOT_TOUCHABLE and never sees a touch to begin with, so this
            // is belt and braces — but it means a bug that leaves the flag off
            // still cannot turn the HUD into something that swallows a tap.
            .then(
                if (state.adjusting) {
                    Modifier.pointerInput(Unit) {
                        detectTransformGestures { _, pan, zoom, _ ->
                            if (pan != Offset.Zero) onDrag(pan.x, pan.y)
                            if (zoom != 1f) onPinch(zoom)
                        }
                    }
                } else {
                    Modifier
                },
            )
            // Wider than the old 168–260 dp, because the card now carries the
            // verdict word and a caption under each number. The window itself
            // is WRAP_CONTENT (see OverlayHost.buildParams), so it simply grows
            // to fit; the only real ceiling is the forbidden bottom band that
            // keeps the HUD off the Accept button, and this stays far inside it.
            .widthIn(min = 210.dp, max = 320.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(HudColors.Surface)
            // Confidence below the threshold means we could not read the whole
            // card. Dimming is an honest signal — far better than rendering a
            // crisp number the driver would trust and act on.
            .alpha(if (economics.verdict == Verdict.UNKNOWN) 0.75f else 1f),
    ) {
        // IntrinsicSize.Min lets the verdict strip match whatever height the
        // content ends up being, instead of guessing a fixed dp that breaks
        // the moment a line wraps.
        Row(Modifier.height(IntrinsicSize.Min)) {
            // Verdict strip — readable from the corner of the eye.
            Box(
                Modifier
                    .width(6.dp)
                    .fillMaxHeight()
                    .background(accent),
            )

            Column(
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(1.dp),
            ) {
                StatusRow(economics, accent)
                Spacer(Modifier.height(6.dp))
                EarningsPerKmRow(economics, accent)
                Caption("what the ride pays per km")
                Spacer(Modifier.height(6.dp))
                NetPerKmRow(economics)
                Caption("what you keep after fuel")
                Spacer(Modifier.height(6.dp))
                ContextRow(economics)

                if (state.adjusting) {
                    Spacer(Modifier.height(10.dp))
                    AdjustBar(state.scale, onDone)
                }
            }
        }
    }
}

/**
 * Shown only while placing the HUD. Says what to do and gives one way out.
 *
 * The way out matters more than it looks: adjust mode is the only state in
 * which this window accepts touch, so leaving it must not depend on the driver
 * finding the app again. Done is right here, on the thing he is dragging.
 */
@Composable
private fun AdjustBar(scale: Float, onDone: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            text = "Drag to move  ·  pinch to resize  ·  ${(scale * 100).roundToInt()}%",
            color = HudColors.Secondary,
            fontSize = 10.sp,
            lineHeight = 13.sp,
            fontWeight = FontWeight.Medium,
        )
        Box(
            Modifier
                .clip(RoundedCornerShape(8.dp))
                .background(HudColors.Good)
                .clickable(onClick = onDone)
                .padding(horizontal = 16.dp, vertical = 7.dp),
        ) {
            Text(
                text = "Done",
                color = Color.White,
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}

/**
 * THE VERDICT, IN WORDS. The line read first, and the only one that survives
 * being glanced at for half a second.
 *
 * Drawn in the accent colour so it reinforces the strip rather than competing
 * with it, and uppercased for the same reason the strip exists at all.
 */
@Composable
private fun StatusRow(e: OfferEconomics, accent: Color) {
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Text(
            text = e.verdict.statusLabel.uppercase(),
            color = accent,
            fontSize = 19.sp,
            lineHeight = 22.sp,
            fontWeight = FontWeight.Black,
        )
        Text(
            text = e.verdict.statusDetail,
            color = HudColors.Secondary,
            fontSize = 10.sp,
            lineHeight = 13.sp,
            fontWeight = FontWeight.Medium,
        )
    }
}

/** The small print under a number, saying what the number actually is. */
@Composable
private fun Caption(text: String) {
    Text(
        text = text,
        color = HudColors.Secondary,
        fontSize = 10.sp,
        lineHeight = 13.sp,
        fontWeight = FontWeight.Medium,
    )
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
            fontSize = 34.sp,
            lineHeight = 38.sp,
            fontWeight = FontWeight.Black,
        )
        Spacer(Modifier.width(3.dp))
        Text(
            text = "/km",
            color = HudColors.Secondary,
            fontSize = 14.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 3.dp),
        )

        Spacer(Modifier.weight(1f))

        // Only shown when there is genuinely something to flag. A badge that
        // is always on screen stops being a warning and becomes decoration.
        //
        // Driven by the calculator's own comparison, not by a threshold copied
        // here: this used to read `ratio > 0.8`, which silently stopped
        // agreeing with the verdict as soon as a driver changed that target.
        val ratio = e.deadheadRatio
        if (ratio != null && e.deadheadIsExcessive) {
            WarningBadge("↩ ${NumberParsing.formatRate(ratio, 1)}×")
        }
    }
}

/**
 * The same number after fuel — the one he actually keeps per km.
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
            fontSize = 19.sp,
            lineHeight = 22.sp,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.width(3.dp))
        // Just the unit here — the caption underneath carries the meaning, and
        // repeating "after fuel" in both places wastes a line the HUD needs.
        Text(
            text = "/km",
            color = HudColors.Secondary,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(bottom = 1.dp),
        )
    }
}

/** Everything else, in one quiet line: total kept, distance, hourly. */
@Composable
private fun ContextRow(e: OfferEconomics) {
    val perHour = e.netPerHour
    // "in total" and "driving" so the two figures cannot be mistaken for the
    // per-km pair above them — the whole point of this line is that it is the
    // WHOLE ride, not a rate.
    val text = buildString {
        append(NumberParsing.formatAuto(e.net))
        append(' ')
        append(e.currency)
        append(" in total  ·  ")
        append(NumberParsing.formatRate(e.totalKm, 1))
        append(" km driving")
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
        lineHeight = 14.sp,
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

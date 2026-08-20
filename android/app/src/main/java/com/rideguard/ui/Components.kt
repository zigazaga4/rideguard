package com.rideguard.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Shared building blocks.
 *
 * Onboarding and Settings ask for the same things — a labelled number, a
 * toggle, a choice from a short list — so they use the same components rather
 * than each growing its own near-identical copy.
 */

/**
 * A number input that survives partial typing.
 *
 * The value is held as a String, not a Double, because binding a Double
 * directly makes the field fight the user: clearing it snaps to "0", and
 * typing "7." is impossible because it is not yet a valid number. We only
 * commit upstream once the text actually parses.
 */
@Composable
fun NumberField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    suffix: String? = null,
    helper: String? = null,
) {
    Column(modifier.fillMaxWidth()) {
        OutlinedTextField(
            value = value,
            onValueChange = { raw ->
                // Accept both decimal conventions while typing — a Romanian
                // driver will reach for the comma without thinking.
                if (raw.isEmpty() || raw.matches(Regex("""^\d{0,7}([.,]\d{0,3})?$"""))) {
                    onValueChange(raw)
                }
            },
            label = { Text(label) },
            suffix = suffix?.let { { Text(it, color = RgColors.Secondary) } },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.fillMaxWidth(),
        )
        helper?.let {
            Text(
                text = it,
                color = RgColors.Secondary,
                fontSize = 11.sp,
                lineHeight = 15.sp,
                modifier = Modifier.padding(start = 4.dp, top = 4.dp),
            )
        }
    }
}

@Composable
fun TextField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = true,
        modifier = modifier.fillMaxWidth(),
    )
}

/** Horizontal chips for a short, mutually exclusive choice. */
@Composable
fun <T> ChipRow(
    options: List<T>,
    selected: T,
    onSelect: (T) -> Unit,
    label: (T) -> String,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        options.forEach { option ->
            val isSelected = option == selected
            Box(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(9.dp))
                    .background(if (isSelected) RgColors.Good else RgColors.SurfaceHigh)
                    .clickable { onSelect(option) }
                    .padding(vertical = 10.dp),
            ) {
                Text(
                    text = label(option),
                    color = if (isSelected) Color.White else RgColors.Secondary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

@Composable
fun SettingSwitch(
    title: String,
    subtitle: String?,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(RgColors.Surface)
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, color = RgColors.Primary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            subtitle?.let {
                Text(it, color = RgColors.Secondary, fontSize = 11.sp, lineHeight = 15.sp)
            }
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

/** A permission or setup step with a live done/not-done state. */
@Composable
fun StepCard(
    title: String,
    body: String,
    actionLabel: String,
    done: Boolean,
    onAction: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(RgColors.Surface)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .clip(RoundedCornerShape(50))
                    .background(if (done) RgColors.Good else RgColors.Marginal)
                    .padding(horizontal = 7.dp, vertical = 2.dp),
            ) {
                Text(
                    text = if (done) "DONE" else "TODO",
                    color = Color.White,
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
            Spacer(Modifier.padding(horizontal = 5.dp))
            Text(title, color = RgColors.Primary, fontSize = 15.sp, fontWeight = FontWeight.Bold)
        }
        Text(body, color = RgColors.Secondary, fontSize = 12.sp, lineHeight = 17.sp)
        if (!done) {
            Spacer(Modifier.height(4.dp))
            PrimaryButton(actionLabel, onClick = onAction)
        }
    }
}

@Composable
fun PrimaryButton(
    label: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(if (enabled) RgColors.Good else RgColors.SurfaceHigh)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 13.dp),
    ) {
        Text(
            text = label,
            color = if (enabled) Color.White else RgColors.Secondary,
            fontSize = 14.sp,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
fun SecondaryButton(label: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier
            .clip(RoundedCornerShape(10.dp))
            .background(RgColors.SurfaceHigh)
            .clickable(onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 13.dp),
    ) {
        Text(label, color = RgColors.Primary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
fun SectionHeader(title: String, subtitle: String? = null) {
    Column(Modifier.padding(top = 8.dp, bottom = 2.dp)) {
        Text(
            title,
            color = RgColors.Primary,
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
            style = MaterialTheme.typography.labelLarge,
        )
        subtitle?.let {
            Text(it, color = RgColors.Secondary, fontSize = 11.sp, lineHeight = 15.sp)
        }
    }
}

@Composable
fun IconRow(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = RgColors.Secondary)
        Spacer(Modifier.padding(horizontal = 5.dp))
        Text(text, color = RgColors.Secondary, fontSize = 12.sp)
    }
}

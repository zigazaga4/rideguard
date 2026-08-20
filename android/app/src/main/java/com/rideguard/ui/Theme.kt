package com.rideguard.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/**
 * Colours shared by the settings UI and the floating HUD.
 *
 * Single source of truth on purpose: when the driver sees green in settings
 * it must be the same green he sees over the offer card, or the traffic-light
 * language stops meaning anything.
 */
object RgColors {
    val Good = Color(0xFF16A34A)
    val Marginal = Color(0xFFF59E0B)
    val Bad = Color(0xFFDC2626)
    val Unknown = Color(0xFF64748B)

    val Background = Color(0xFF0F1114)
    val Surface = Color(0xFF161A1F)
    val SurfaceHigh = Color(0xFF1E242B)
    val Primary = Color(0xFFF5F7FA)
    val Secondary = Color(0xFF9AA4B2)
    val Outline = Color(0xFF2A323B)
}

private val DarkScheme = darkColorScheme(
    primary = RgColors.Good,
    onPrimary = Color.White,
    background = RgColors.Background,
    onBackground = RgColors.Primary,
    surface = RgColors.Surface,
    onSurface = RgColors.Primary,
    surfaceVariant = RgColors.SurfaceHigh,
    onSurfaceVariant = RgColors.Secondary,
    outline = RgColors.Outline,
    error = RgColors.Bad,
)

/**
 * Dark only, and deliberately so. This app is used in a car, often at night,
 * frequently alongside a map. A light theme would be actively hostile.
 */
private val LightScheme = lightColorScheme(
    primary = RgColors.Good,
    background = RgColors.Background,
    surface = RgColors.Surface,
)

@Composable
fun RideGuardTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkScheme else DarkScheme,
        content = content,
    )
}

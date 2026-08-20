package com.rideguard

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.text.TextUtils

/**
 * The permission maze.
 *
 * This is genuinely the hardest UX in the app, and it is worth understanding
 * why: **not one of these can be granted programmatically.** Every single one
 * is a system screen we can only deep-link to and then ask the driver to flip
 * a switch himself. Budget real time for this flow; it is where users give up.
 */
object Permissions {

    /**
     * Can we draw over other apps?
     *
     * Only relevant to the `play` / OCR flavour. On the sideload flavour the
     * overlay is added from inside the AccessibilityService using
     * TYPE_ACCESSIBILITY_OVERLAY, which needs no grant at all — one fewer
     * intimidating screen for the driver.
     */
    fun canDrawOverlays(context: Context): Boolean = Settings.canDrawOverlays(context)

    fun overlaySettingsIntent(context: Context): Intent = Intent(
        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
        Uri.parse("package:${context.packageName}"),
    )

    /**
     * Is our accessibility service switched on?
     *
     * Read from Settings.Secure rather than by asking the service, because
     * before the user enables it the service does not exist to ask.
     */
    fun isAccessibilityServiceEnabled(context: Context, serviceClass: Class<*>): Boolean =
        isAccessibilityServiceEnabled(context, serviceClass.name)

    /**
     * Class-name overload.
     *
     * The service class only exists in the `sideload` flavour, so shared code
     * cannot reference it as a `Class<*>` without breaking the `play` build.
     * A string keeps the check flavour-agnostic.
     */
    fun isAccessibilityServiceEnabled(context: Context, serviceClassName: String): Boolean {
        val expected = ComponentName(context.packageName, serviceClassName).flattenToString()
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false

        val splitter = TextUtils.SimpleStringSplitter(':').apply { setString(enabled) }
        while (splitter.hasNext()) {
            val component = splitter.next()
            if (component.equals(expected, ignoreCase = true)) return true
            // Some OEMs store the short form; compare the class as a fallback.
            if (component.endsWith("/$serviceClassName", ignoreCase = true)) return true
        }
        return false
    }

    /** Fully-qualified name of the sideload-only reader service. */
    const val ACCESSIBILITY_SERVICE_CLASS = "com.rideguard.service.RideGuardAccessibilityService"

    fun accessibilitySettingsIntent(): Intent =
        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /**
     * Stock Android's own battery saver. Necessary but NOT sufficient — see
     * [oemAutostartHint].
     */
    fun isIgnoringBatteryOptimizations(context: Context): Boolean {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(context.packageName)
    }

    @Suppress("BatteryLife") // Deliberate: a reader that gets killed mid-shift is useless.
    fun batteryOptimizationIntent(context: Context): Intent = Intent(
        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
        Uri.parse("package:${context.packageName}"),
    )

    fun notificationsGranted(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

    /**
     * Xiaomi, Huawei, Oppo, Vivo and Samsung all run their own background
     * killers that ignore the standard exemption above. There is no API to
     * check or request this — the driver must find the autostart screen in
     * his phone's own settings app.
     *
     * dontkillmyapp.com documents the exact path per vendor and is the right
     * thing to link from onboarding.
     */
    fun oemAutostartHint(): String? = when (Build.MANUFACTURER.lowercase()) {
        "xiaomi", "redmi", "poco" ->
            "Xiaomi: Settings → Apps → RideGuard → Autostart ON, and set Battery saver to \"No restrictions\"."
        "huawei", "honor" ->
            "Huawei: Settings → Battery → App launch → RideGuard → Manage manually, all three switches ON."
        "oppo", "realme", "oneplus" ->
            "Oppo/OnePlus: Settings → Battery → App battery usage → RideGuard → Allow background activity."
        "vivo", "iqoo" ->
            "Vivo: Settings → Battery → Background power consumption → allow RideGuard."
        "samsung" ->
            "Samsung: Settings → Apps → RideGuard → Battery → Unrestricted, and remove it from Sleeping apps."
        else -> null
    }

    const val DONT_KILL_MY_APP_URL = "https://dontkillmyapp.com"
}

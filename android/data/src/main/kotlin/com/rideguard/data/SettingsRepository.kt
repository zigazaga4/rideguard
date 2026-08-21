package com.rideguard.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.rideguard.domain.model.DriverThresholds
import com.rideguard.domain.model.FuelType
import com.rideguard.domain.model.Platform
import com.rideguard.domain.model.VehicleProfile
import com.rideguard.domain.pipeline.PipelineSettings
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "rideguard_settings")

/**
 * How far the driver may scale the HUD.
 *
 * Floors and ceilings rather than free rein: below ~0.7 the type stops being
 * legible at a glance in a moving car, which is the only thing this HUD is
 * for, and above ~2.0 it starts to reach the forbidden bottom band no matter
 * where it is positioned. Duplicated as plain constants here, and mirrored in
 * `OverlayScale`, because `:data` and `:overlay` do not depend on each other.
 */
const val HUD_SCALE_MIN = 0.7f
const val HUD_SCALE_MAX = 2.0f

/**
 * Everything the driver configures, in one place.
 *
 * Exposed as a [Flow] of [PipelineSettings] so that changing the fuel price
 * in settings re-evaluates the live pipeline immediately — no restart, no
 * service bounce. The pipeline's `flatMapLatest` picks it straight up.
 */
class SettingsRepository(context: Context) {

    private val store = context.applicationContext.dataStore

    // ------------------------------------------------------------------ keys

    private object Keys {
        val VEHICLE_LABEL = stringPreferencesKey("vehicle_label")
        val FUEL_TYPE = stringPreferencesKey("fuel_type")
        val CONSUMPTION = doublePreferencesKey("consumption_per_100km")
        val ENERGY_PRICE = doublePreferencesKey("energy_price")
        val CURRENCY = stringPreferencesKey("currency")

        val MIN_NET_PER_HOUR = doublePreferencesKey("min_net_per_hour")
        val MIN_NET_PER_KM = doublePreferencesKey("min_net_per_km")
        val MAX_DEADHEAD = doublePreferencesKey("max_deadhead_ratio")
        val MIN_NET_TOTAL = doublePreferencesKey("min_net_total")

        val ONBOARDED = booleanPreferencesKey("onboarding_complete")
        val RECORD_MODE = booleanPreferencesKey("record_mode")
        val HUD_ENABLED = booleanPreferencesKey("hud_enabled")

        fun commission(p: Platform) = doublePreferencesKey("commission_${p.name}")
        fun fareIsNet(p: Platform) = booleanPreferencesKey("fare_is_net_${p.name}")

        // Position and size are remembered PER PLATFORM because Bolt and Uber
        // lay their offer cards out differently — one saved geometry would be
        // wrong on one of them.
        fun posX(p: Platform) = intPreferencesKey("hud_x_${p.name}")
        fun posY(p: Platform) = intPreferencesKey("hud_y_${p.name}")
        fun scale(p: Platform) = floatPreferencesKey("hud_scale_${p.name}")

        /**
         * Set while the driver is placing the HUD by hand.
         *
         * Lives in DataStore rather than in a binder call because the thing
         * that owns the overlay is a service and the thing the driver taps is
         * an Activity. Both already collect from this store, so a flag here is
         * the whole mechanism — no new IPC, and it survives the Activity going
         * away mid-adjust.
         */
        val HUD_ADJUST = booleanPreferencesKey("hud_adjust_mode")
    }

    // ---------------------------------------------------------------- reads

    val settings: Flow<PipelineSettings> = store.data.map { prefs -> prefs.toPipelineSettings() }

    val isOnboarded: Flow<Boolean> = store.data.map { it[Keys.ONBOARDED] ?: false }
    val recordModeEnabled: Flow<Boolean> = store.data.map { it[Keys.RECORD_MODE] ?: false }
    val hudEnabled: Flow<Boolean> = store.data.map { it[Keys.HUD_ENABLED] ?: true }

    val vehicle: Flow<VehicleProfile> = store.data.map { it.toVehicle() }
    val thresholds: Flow<DriverThresholds> = store.data.map { it.toThresholds() }

    fun hudPosition(platform: Platform): Flow<Pair<Int, Int>?> = store.data.map { prefs ->
        val x = prefs[Keys.posX(platform)]
        val y = prefs[Keys.posY(platform)]
        if (x != null && y != null) x to y else null
    }

    /** 1.0 until the driver resizes it. Clamped on read as well as on write,
     *  because a value written by a build with different bounds must not be
     *  able to produce a HUD the size of the screen. */
    fun hudScale(platform: Platform): Flow<Float> = store.data.map { prefs ->
        (prefs[Keys.scale(platform)] ?: 1f).coerceIn(HUD_SCALE_MIN, HUD_SCALE_MAX)
    }

    val hudAdjustMode: Flow<Boolean> = store.data.map { it[Keys.HUD_ADJUST] ?: false }

    // --------------------------------------------------------------- writes

    suspend fun saveVehicle(profile: VehicleProfile) {
        store.edit { p ->
            p[Keys.VEHICLE_LABEL] = profile.label
            p[Keys.FUEL_TYPE] = profile.fuelType.name
            p[Keys.CONSUMPTION] = profile.consumptionPer100km
            p[Keys.ENERGY_PRICE] = profile.energyPrice
            p[Keys.CURRENCY] = profile.currency
        }
    }

    suspend fun saveThresholds(t: DriverThresholds) {
        store.edit { p ->
            p[Keys.MIN_NET_PER_HOUR] = t.minNetPerHour
            p[Keys.MIN_NET_PER_KM] = t.minNetPerKm
            p[Keys.MAX_DEADHEAD] = t.maxDeadheadRatio
            p[Keys.MIN_NET_TOTAL] = t.minNetTotal
        }
    }

    suspend fun savePlatformConfig(platform: Platform, commissionRate: Double, fareIsNet: Boolean) {
        store.edit { p ->
            p[Keys.commission(platform)] = commissionRate.coerceIn(0.0, 0.95)
            p[Keys.fareIsNet(platform)] = fareIsNet
        }
    }

    suspend fun saveHudPosition(platform: Platform, x: Int, y: Int) {
        store.edit { p ->
            p[Keys.posX(platform)] = x
            p[Keys.posY(platform)] = y
        }
    }

    /** Written once, when the driver finishes placing the HUD. One edit rather
     *  than three so a crash mid-adjust cannot leave a saved size that belongs
     *  to a different saved position. */
    suspend fun saveHudLayout(platform: Platform, x: Int, y: Int, scale: Float) {
        store.edit { p ->
            p[Keys.posX(platform)] = x
            p[Keys.posY(platform)] = y
            p[Keys.scale(platform)] = scale.coerceIn(HUD_SCALE_MIN, HUD_SCALE_MAX)
        }
    }

    suspend fun setHudAdjustMode(value: Boolean) {
        store.edit { it[Keys.HUD_ADJUST] = value }
    }

    // Explicit `Unit` return, not an expression body. `store.edit {}` returns
    // DataStore's `Preferences`, which would leak the persistence library out
    // through this repository's public API and force every caller to have
    // DataStore on its compile classpath. Callers want none of that.
    suspend fun setOnboarded(value: Boolean) {
        store.edit { it[Keys.ONBOARDED] = value }
    }

    suspend fun setRecordMode(value: Boolean) {
        store.edit { it[Keys.RECORD_MODE] = value }
    }

    suspend fun setHudEnabled(value: Boolean) {
        store.edit { it[Keys.HUD_ENABLED] = value }
    }

    // -------------------------------------------------------------- mapping

    private fun Preferences.toVehicle(): VehicleProfile {
        val defaults = VehicleProfile.DEFAULT_RO
        return VehicleProfile(
            label = this[Keys.VEHICLE_LABEL] ?: defaults.label,
            fuelType = this[Keys.FUEL_TYPE]
                ?.let { name -> runCatching { FuelType.valueOf(name) }.getOrNull() }
                ?: defaults.fuelType,
            consumptionPer100km = this[Keys.CONSUMPTION] ?: defaults.consumptionPer100km,
            energyPrice = this[Keys.ENERGY_PRICE] ?: defaults.energyPrice,
            currency = this[Keys.CURRENCY] ?: defaults.currency,
        )
    }

    private fun Preferences.toThresholds(): DriverThresholds {
        val d = DriverThresholds()
        return DriverThresholds(
            minNetPerHour = this[Keys.MIN_NET_PER_HOUR] ?: d.minNetPerHour,
            minNetPerKm = this[Keys.MIN_NET_PER_KM] ?: d.minNetPerKm,
            maxDeadheadRatio = this[Keys.MAX_DEADHEAD] ?: d.maxDeadheadRatio,
            minNetTotal = this[Keys.MIN_NET_TOTAL] ?: d.minNetTotal,
        )
    }

    private fun Preferences.toPipelineSettings() = PipelineSettings(
        vehicle = toVehicle(),
        thresholds = toThresholds(),
        commissionByPlatform = Platform.entries.associateWith { p ->
            this[Keys.commission(p)] ?: p.defaultCommissionRate
        },
        fareIsNetByPlatform = Platform.entries.associateWith { p ->
            this[Keys.fareIsNet(p)] ?: p.fareShownIsNetByDefault
        },
    )
}

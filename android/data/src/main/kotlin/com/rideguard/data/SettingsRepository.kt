package com.rideguard.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
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

        // Position is remembered PER PLATFORM because Bolt and Uber lay their
        // offer cards out differently — one saved position would be wrong on
        // one of them.
        fun posX(p: Platform) = intPreferencesKey("hud_x_${p.name}")
        fun posY(p: Platform) = intPreferencesKey("hud_y_${p.name}")
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

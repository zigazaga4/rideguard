package com.rideguard

import android.app.Application
import com.rideguard.data.SettingsRepository

/**
 * Manual DI.
 *
 * The graph here is two objects deep. Hilt would add a compiler plugin, a
 * build-time cost and a layer of generated indirection to solve a problem
 * this app does not have — and the AccessibilityService, which is the piece
 * that most needs the repository, is constructed by the system anyway and so
 * would need manual wiring regardless.
 */
class RideGuardApp : Application() {

    val settings: SettingsRepository by lazy { SettingsRepository(this) }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    companion object {
        lateinit var instance: RideGuardApp
            private set
    }
}

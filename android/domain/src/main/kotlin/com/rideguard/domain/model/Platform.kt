package com.rideguard.domain.model

/**
 * A ride-hailing driver app we can read offers from.
 *
 * [packageName] is what goes in `accessibility_service_config.xml` so the
 * service stays completely dormant outside these apps — the single most
 * important battery decision in the whole app.
 */
enum class Platform(
    val packageName: String,
    val displayName: String,
    /**
     * Default platform take rate. Varies by country, driver tier and
     * promotion, so it is only a starting value — the driver overrides it in
     * settings after checking a real payout statement.
     */
    val defaultCommissionRate: Double,
    /**
     * Whether the fare shown on the offer card is ALREADY net of commission.
     * This differs by market and is the single easiest way to be quietly
     * wrong by 20%. Always verify against a real weekly statement.
     */
    val fareShownIsNetByDefault: Boolean,
) {
    /**
     * Romanian Bolt driver app spells it out on the card itself:
     *
     *     11,62 lei (NET, taxe incluse)
     *
     * Net, taxes already included. So there is nothing left to subtract. The
     * app previously defaulted this to gross with a 20% take rate, which made
     * every Bolt offer read 20% worse than it really was — a pessimistic HUD
     * is still a wrong HUD, and it would have talked the driver out of rides
     * that were actually fine.
     */
    BOLT(
        packageName = "ee.mtakso.driver",
        displayName = "Bolt",
        defaultCommissionRate = 0.0,
        fareShownIsNetByDefault = true,
    ),

    /**
     * Uber Romania labels the fare "Câștig net (fără comisionul Uber)" —
     * net earnings, Uber's commission already taken out. Same story.
     */
    UBER(
        packageName = "com.ubercab.driver",
        displayName = "Uber",
        defaultCommissionRate = 0.0,
        fareShownIsNetByDefault = true,
    ),
    UNKNOWN(
        packageName = "",
        displayName = "Unknown",
        defaultCommissionRate = 0.0,
        fareShownIsNetByDefault = true,
    ),
    ;

    companion object {
        fun fromPackage(pkg: String?): Platform =
            entries.firstOrNull { it.packageName.isNotEmpty() && it.packageName == pkg } ?: UNKNOWN

        /** Packages the accessibility service should listen to. */
        val watchedPackages: List<String> =
            entries.map { it.packageName }.filter { it.isNotEmpty() }
    }
}

package com.rideguard.domain.model

/**
 * How the driver's car burns money. Captured during onboarding — this is the
 * whole reason the app can compute a REAL number instead of a gross fare.
 */
enum class FuelType(
    val displayName: String,
    /** "L" for liquid fuels, "kWh" for electric. Drives the onboarding copy. */
    val unitLabel: String,
    /** "L/100km" or "kWh/100km". */
    val consumptionLabel: String,
) {
    PETROL("Petrol", "L", "L/100km"),
    DIESEL("Diesel", "L", "L/100km"),
    LPG("LPG / GPL", "L", "L/100km"),
    HYBRID("Hybrid", "L", "L/100km"),
    ELECTRIC("Electric", "kWh", "kWh/100km"),
    ;

    val isElectric: Boolean get() = this == ELECTRIC
}

/**
 * The driver's vehicle and running costs.
 *
 * [consumptionPer100km] and [energyPrice] are the two numbers the driver is
 * asked for during onboarding. Everything else has a sane default so the
 * first-run flow stays short — a driver setting this up in a car park will
 * not fill in fourteen fields.
 */
data class VehicleProfile(
    val label: String = "My car",
    val fuelType: FuelType = FuelType.PETROL,
    /** Litres (or kWh) per 100 km. Real-world figure, not the brochure one. */
    val consumptionPer100km: Double = 7.0,
    /** Price per litre (or per kWh) at the driver's usual station. */
    val energyPrice: Double = 7.5,
    val currency: String = "RON",
) {
    /** Cost of energy alone, per kilometre. */
    val energyCostPerKm: Double
        get() = (consumptionPer100km / 100.0) * energyPrice

    /**
     * Marginal cost of putting one more kilometre on this car.
     *
     * Fuel only. Tyres, servicing and depreciation are real costs, but asking
     * a driver to put a number on them at a petrol station is asking him to
     * invent one — and an invented input propagates into every verdict looking
     * exactly as authoritative as the two figures he actually knows. Two
     * honest inputs beat three where one is a guess.
     */
    val totalCostPerKm: Double
        get() = energyCostPerKm

    fun isPlausible(): Boolean =
        consumptionPer100km > 0.0 &&
            consumptionPer100km < 100.0 &&
            energyPrice > 0.0

    companion object {
        /**
         * Sensible starting point for a Romanian Bolt/Uber driver:
         * ~7 L/100km petrol at ~7.5 RON/L.
         */
        val DEFAULT_RO = VehicleProfile()
    }
}

/**
 * The bar an offer has to clear. Drives the green / amber / red verdict.
 *
 * Defaults are deliberately modest so a new user is not drowned in red on
 * day one; the settings screen nudges them to raise it once they have a
 * week of history to look at.
 */
data class DriverThresholds(
    /** Minimum acceptable NET earnings per hour, after all costs. */
    val minNetPerHour: Double = 40.0,
    /** Minimum acceptable NET earnings per kilometre driven. */
    val minNetPerKm: Double = 1.5,
    /**
     * Maximum tolerable pickup-km ÷ trip-km. Above roughly 1.0 you are
     * driving further to collect than you are paid to carry. This is the
     * number that catches the deceptively-fine-looking bad offer.
     */
    val maxDeadheadRatio: Double = 0.8,
    /** Offers below this absolute net are rejected regardless of rates. */
    val minNetTotal: Double = 0.0,
)

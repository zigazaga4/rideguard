plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

// NOTE: This module is deliberately a PURE KOTLIN JVM module.
// It must never depend on Android. That is what keeps parsing and profit
// maths unit-testable on the JVM in milliseconds, with no emulator and no
// device, and what lets the iOS codebase mirror it 1:1.
// If you ever find yourself wanting `android.graphics.Rect` in here, add a
// plain data class instead (see model/Bounds.kt).

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(libs.kotlinx.coroutines.core)

    // Fixtures are JSON so that recorded offer cards load on the JVM. This is
    // what turns parser work into ordinary unit testing instead of debugging
    // in a parked car.
    api(libs.kotlinx.serialization.json)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}

tasks.withType<Test> {
    testLogging {
        events("passed", "skipped", "failed")
    }
}

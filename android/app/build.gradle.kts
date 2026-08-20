// Imported explicitly: inside a `.gradle.kts` script `java` resolves to the
// Java plugin extension, not the package, so `java.util.Properties` does not
// compile.
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

/**
 * Release signing, loaded from OUTSIDE the repository.
 *
 * The in-app updater replaces this app with an APK downloaded from GitHub, and
 * Android refuses to replace an installed app with one signed by a different
 * key. So the signing identity is not cosmetic here — it is the thing that
 * makes updating possible at all. Lose this keystore and every existing
 * install becomes un-updatable and has to be manually uninstalled.
 *
 * Kept at ~/.rideguard/ rather than in the tree because a signing key in git
 * is a signing key on the internet. When the file is absent (CI, a fresh
 * clone, a second machine) the build still works and simply falls back to
 * debug signing — a broken build is a worse failure than an unsigned one.
 */
val keystoreProperties = Properties().apply {
    val f = File(System.getProperty("user.home"), ".rideguard/keystore.properties")
    if (f.exists()) f.inputStream().use { stream -> load(stream) }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile")?.let { File(it).exists() } == true

android {
    namespace = "com.rideguard"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.rideguard"
        minSdk = 26          // TYPE_APPLICATION_OVERLAY landed in Oreo
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    /**
     * Two flavours, one codebase.
     *
     * `sideload` — AccessibilityService reader. Fast, battery-cheap, and it
     *   gets TYPE_ACCESSIBILITY_OVERLAY for free (no "draw over other apps"
     *   prompt, and immune to setHideOverlayWindows). This is the build for
     *   you and your friend, distributed as an APK.
     *
     * `play`     — MediaProjection + ML Kit OCR reader. Slower and heavier,
     *   but Google Play rejects AccessibilityService use for anything that
     *   is not genuine assistive technology, and a ride-profit analyser is
     *   not. Every app in this category that ships on Play uses OCR.
     *
     * The `ScreenSource` interface is what makes this a build-config swap
     * rather than two forks.
     */
    flavorDimensions += "distribution"
    productFlavors {
        create("sideload") {
            dimension = "distribution"
            applicationIdSuffix = ".sideload"
            versionNameSuffix = "-sideload"
            buildConfigField("boolean", "USE_ACCESSIBILITY", "true")
        }
        create("play") {
            dimension = "distribution"
            buildConfigField("boolean", "USE_ACCESSIBILITY", "false")
        }
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = File(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            /*
             * Shrinking is OFF, on purpose, for now.
             *
             * The release variant has never been built or run — until this
             * commit the `proguard-rules.pro` it referenced did not even
             * exist. The app IS confirmed working as an unminified build on a
             * real phone, and this is the build the updater will start pushing
             * to that phone.
             *
             * Turning R8 on at the same moment as shipping the first
             * self-installing release would stack two unverified changes on
             * top of each other, and the failure mode — a stripped
             * AccessibilityService or a missing serializer — shows up as a
             * silently dead HUD mid-shift, not as a build error.
             *
             * The rules are written and waiting in proguard-rules.pro. Flip
             * these to true, build, and verify the HUD on a real offer before
             * publishing that build.
             */
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")

            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                // So a clone without the key still produces an installable APK.
                signingConfigs.getByName("debug")
            }
        }
        debug {
            applicationIdSuffix = ".debug"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation(project(":domain"))
    implementation(project(":capture"))
    implementation(project(":overlay"))
    implementation(project(":data"))
    implementation(project(":update"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.service)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)
    implementation(libs.kotlinx.coroutines.android)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit)
}

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

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

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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

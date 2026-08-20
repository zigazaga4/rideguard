plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.rideguard.update"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

// Deliberately NO HTTP library.
//
// This module fetches one small JSON file and streams one APK. `HttpURLConnection`
// from the JDK does both perfectly well, and the alternative is adding OkHttp or
// Ktor — hundreds of kilobytes and a transitive dependency graph — to an APK that
// is already ~60 MB because of ML Kit. The updater is also the one component that
// must never fail to build or run: fewer moving parts is the feature.
dependencies {
    api(project(":domain"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinx.coroutines.android)

    testImplementation(libs.junit)
}

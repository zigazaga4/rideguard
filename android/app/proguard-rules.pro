# R8 / ProGuard rules for the release build.
#
# NOTE: shrinking is currently DISABLED in build.gradle.kts. These rules are
# written and ready, but turning R8 on is a separate change that has to be
# verified on a real phone — see the comment on the `release` build type.
# Everything below is what that verification will need.

# --- kotlinx.serialization -------------------------------------------------
# Serializers are generated as companion objects and looked up reflectively.
# Without these, recorded offer fixtures and the update manifest fail to parse
# at runtime with a SerializationException that never appears in a debug build.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.rideguard.**$$serializer { *; }
-keepclassmembers class com.rideguard.** {
    *** Companion;
    *** serializer(...);
}
-keepclasseswithmembers class com.rideguard.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# --- The domain model ------------------------------------------------------
# Serialized to JSON fixtures by record mode and read back on the JVM by the
# parser tests. Renaming these fields silently breaks that round trip.
-keep class com.rideguard.domain.model.** { *; }
-keep class com.rideguard.domain.update.** { *; }

# --- AccessibilityService --------------------------------------------------
# Instantiated by the system from the name in the manifest, so nothing in the
# app references it directly and R8 would happily strip it.
-keep class com.rideguard.service.** { *; }

# --- PackageInstaller result receiver --------------------------------------
# Same story: resolved by class name out of an Intent.
-keep class com.rideguard.update.InstallResultReceiver { *; }

# --- ML Kit ----------------------------------------------------------------
# Only the `play` flavour uses OCR, but the dependency is present in both.
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**

# --- Compose ---------------------------------------------------------------
-dontwarn androidx.compose.**

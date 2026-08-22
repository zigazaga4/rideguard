#!/bin/bash
#
# Boot the Android emulator with BOTH apps on it, ready to test.
#
#   1. RideGuard  (sideload flavour — the AccessibilityService reader)
#   2. RideGuard Mock  (the fake Bolt/Uber offer generator)
#
# You need both. RideGuard on its own has nothing to read: Bolt Driver and
# Uber Driver are not installed on an emulator and would not hand out offers
# if they were. The mock exists to put a realistic offer card on screen so the
# HUD has something to react to — the reader's package whitelist already
# includes `com.rideguard.mock` for exactly this.
#
# Double-clickable from the Desktop via "RideGuard Android.command". Safe to
# run at any time: it reuses a booted emulator, installs over whatever is
# already there, and relaunches. Your settings survive, because installing
# over an app keeps its container.

set -euo pipefail

ANDROID_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$ANDROID_DIR/.." && pwd)"
MOCK_DIR="$REPO_DIR/mock"

AVD_NAME="RideGuard_API35"
SYSTEM_IMAGE="system-images;android-35;google_apis;x86_64"

APP_ID="com.rideguard.sideload.debug"
A11Y_SERVICE="$APP_ID/com.rideguard.service.RideGuardAccessibilityService"
MOCK_ID="com.rideguard.mock"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '\033[32m  ok\033[0m  %s\n' "$1"; }
warn() { printf '\033[33m  !!\033[0m  %s\n' "$1"; }
die()  { printf '\n\033[31mfailed:\033[0m %s\n\n' "$1" >&2; exit 1; }

# --- Toolchain --------------------------------------------------------------
#
# Resolved here rather than inherited, because a double-clicked .command gets
# a login shell with none of the exports a terminal session picks up.

if [ -z "${JAVA_HOME:-}" ] || [ ! -x "${JAVA_HOME:-}/bin/java" ]; then
    for candidate in \
        /usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
        /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
        "$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
    do
        if [ -n "$candidate" ] && [ -x "$candidate/bin/java" ]; then
            export JAVA_HOME="$candidate"
            break
        fi
    done
fi
[ -n "${JAVA_HOME:-}" ] || die "no JDK 17 found — brew install openjdk@17"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

[ -x "$ANDROID_HOME/platform-tools/adb" ] || die "no Android SDK at $ANDROID_HOME"
ok "jdk $(basename "$(dirname "$(dirname "$JAVA_HOME")")" 2>/dev/null || echo 17)"

# Gradle reads the SDK location from here. Machine-local and gitignored, so a
# fresh clone will not have one.
if [ ! -f "$ANDROID_DIR/local.properties" ]; then
    printf '## Machine-local, not checked in.\nsdk.dir=%s\n' "$ANDROID_HOME" \
        > "$ANDROID_DIR/local.properties"
    ok "wrote local.properties"
fi

# --- Emulator ---------------------------------------------------------------

bold "==> Emulator"

if ! emulator -list-avds 2>/dev/null | grep -qx "$AVD_NAME"; then
    [ -d "$ANDROID_HOME/system-images/android-35" ] \
        || die "no system image — sdkmanager \"$SYSTEM_IMAGE\""
    echo no | avdmanager create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE" -d pixel_6 --force >/dev/null
    ok "created AVD $AVD_NAME"
fi

# Reuse whatever is already booted. Cold-booting a second copy would take two
# minutes and then fight the first one over the adb port.
if adb devices | grep -q 'emulator-.*device$'; then
    ok "emulator already running"
else
    # nohup + disown: the emulator has to outlive this script, or the window
    # closing at the end would take the phone with it.
    nohup emulator -avd "$AVD_NAME" -gpu auto -no-boot-anim \
        >/tmp/rideguard-emulator.log 2>&1 &
    disown
    printf '  starting %s' "$AVD_NAME"

    for _ in $(seq 1 60); do
        if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
            break
        fi
        printf '.'
        sleep 5
    done
    printf '\n'

    [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] \
        || die "emulator did not finish booting — see /tmp/rideguard-emulator.log"
    ok "booted"
fi

adb wait-for-device >/dev/null

# --- 1. RideGuard -----------------------------------------------------------

bold "==> Building RideGuard"
cd "$ANDROID_DIR"
if ! ./gradlew :app:assembleSideloadDebug -q 2>&1 | tail -40; then
    die "RideGuard did not build"
fi
ok "sideload debug built"

adb install -r app/build/outputs/apk/sideload/debug/app-sideload-debug.apk >/dev/null
ok "RideGuard installed"

# --- 2. The mock offer generator --------------------------------------------
#
# Expo generates the native project on demand; it is gitignored, so the first
# run does a prebuild and later runs skip it.
#
# Built as RELEASE on purpose. A debug React Native build loads its JavaScript
# from a Metro dev server, which would mean leaving a second terminal running
# for the mock to work at all. Release bundles the JS into the APK and signs it
# with the debug keystore, so the phone keeps working after this window closes.

bold "==> Building the mock offer generator"
if command -v node >/dev/null 2>&1; then
    cd "$MOCK_DIR"

    [ -d node_modules ] || { npm install >/dev/null 2>&1 && ok "npm install"; }

    if [ ! -d android ]; then
        printf '  generating the native project (one-off, slow)\n'
        npx expo prebuild --platform android --no-install >/dev/null 2>&1 \
            || warn "expo prebuild failed"
    fi

    if [ -d android ]; then
        if (cd android && ./gradlew assembleRelease -q >/dev/null 2>&1); then
            apk=$(find android/app/build/outputs/apk/release -name '*.apk' | head -1)
            adb install -r "$apk" >/dev/null && ok "mock installed"
        else
            warn "the mock did not build — run 'cd mock && npm run android' by hand"
        fi
    fi
else
    warn "node is not installed, so the mock was skipped (brew install node)"
fi

# --- Switch the reader on ---------------------------------------------------
#
# This is normally a manual trip through Settings → Accessibility. On an
# emulator adb holds WRITE_SECURE_SETTINGS, so the launcher can do it for you.
#
# It has to happen AFTER the install: Android clears a service out of this list
# whenever its package is replaced, so enabling it first would silently undo
# itself.

bold "==> Switching the reader on"
current=$(adb shell settings get secure enabled_accessibility_services | tr -d '\r')
case "$current" in
    *"$A11Y_SERVICE"*) ok "reader already enabled" ;;
    null|"")
        adb shell settings put secure enabled_accessibility_services "$A11Y_SERVICE"
        adb shell settings put secure accessibility_enabled 1
        ok "reader enabled"
        ;;
    *)
        # Append rather than overwrite — clobbering the list would switch off
        # any other accessibility service on the device.
        adb shell settings put secure enabled_accessibility_services "$current:$A11Y_SERVICE"
        adb shell settings put secure accessibility_enabled 1
        ok "reader enabled"
        ;;
esac

adb shell pm grant "$APP_ID" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
adb shell dumpsys deviceidle whitelist "+$APP_ID" >/dev/null 2>&1 || true
ok "notifications + battery exemption granted"

# --- Go ---------------------------------------------------------------------

adb shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
bold "Ready."
printf '  RideGuard is open. Switch to "RideGuard Mock" on the phone to\n'
printf '  generate an offer, and the HUD will appear over it.\n\n'
printf '  The emulator stays running after this window closes.\n\n'

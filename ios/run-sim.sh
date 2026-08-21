#!/bin/bash
#
# Build the current working tree and put it on the Simulator, running.
#
# Double-clickable from the Desktop via RideGuard.command. Safe to run at any
# time: it regenerates the Xcode project, builds, installs over whatever is
# already there, and relaunches. Existing settings and history survive, because
# installing over an app keeps its container.
#
# Signing is off. This only ever targets the Simulator, which does not check
# signatures, and requiring a Team here would mean a broken launcher every time
# a certificate expires.

set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$IOS_DIR"

BUNDLE_ID="com.priemschi.rideguard.app"
PREFERRED_SIM="RideGuard iPhone 17 Pro"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '\033[32m  ok\033[0m  %s\n' "$1"; }
die()  { printf '\033[31mfailed:\033[0m %s\n' "$1" >&2; exit 1; }

# --- Pick a simulator -------------------------------------------------------
#
# Prefer the named one, fall back to anything already booted, then to any
# available iPhone. Hard-coding a UDID would rot the first time the user
# deletes a device.
udid=$(xcrun simctl list devices available \
       | grep "$PREFERRED_SIM (" | head -1 \
       | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/') || true

if [ -z "${udid:-}" ]; then
    udid=$(xcrun simctl list devices booted \
           | sed -E -n 's/.*\(([0-9A-F-]{36})\) \(Booted\).*/\1/p' | head -1) || true
fi

if [ -z "${udid:-}" ]; then
    udid=$(xcrun simctl list devices available \
           | grep -E '^\s+iPhone' | head -1 \
           | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/') || true
fi

[ -n "${udid:-}" ] || die "no iOS Simulator is available — open Xcode once and install a runtime"
ok "simulator $udid"

# --- Build ------------------------------------------------------------------

bold "==> Regenerating the Xcode project"
command -v xcodegen >/dev/null 2>&1 || die "xcodegen is not installed (brew install xcodegen)"
xcodegen generate >/dev/null
ok "project generated from project.yml"

bold "==> Building"
# Errors are surfaced, the rest is swallowed: this window is for the driver of
# the app, not for reading a compile log.
if ! xcodebuild \
        -project RideGuard.xcodeproj \
        -scheme RideGuard \
        -sdk iphonesimulator \
        -destination "id=$udid" \
        -derivedDataPath build/sim \
        CODE_SIGNING_ALLOWED=NO \
        build 2>&1 | grep -E '(error|warning): ' | head -40; then
    :
fi

APP="build/sim/Build/Products/Debug-iphonesimulator/RideGuard.app"
[ -d "$APP" ] || die "build produced no app — scroll up for the first 'error:' line"
ok "built $(basename "$APP")"

# --- Install and run --------------------------------------------------------

bold "==> Starting the Simulator"
open -a Simulator
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
ok "booted"

xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$udid" "$APP"
ok "installed"

xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
ok "launched"

printf '\n\033[32m\033[1mRideGuard is running.\033[0m\n'
printf 'Note: the Simulator has no ReplayKit broadcast and no Picture-in-Picture,\n'
printf 'so the Live HUD tab cannot actually float a window here. Everything else\n'
printf '— onboarding, Quick check, Settings, History — is real.\n\n'
printf 'To start over at first-run, delete the app in the Simulator first\n'
printf '(long-press the icon), then run this again.\n\n'

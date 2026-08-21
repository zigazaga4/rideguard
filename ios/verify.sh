#!/usr/bin/env bash
#
# Everything that can be checked without an Apple Developer account, in order,
# cheapest first.
#
#     ./verify.sh
#
# The point is to separate "the code is wrong" from "the signing is wrong".
# Those two failures look identical in Xcode's issue navigator and are fixed in
# completely different places, so this builds with signing switched OFF and for
# the Simulator only. If this script is green, every line compiles and the
# domain maths is correct; all that is left is certificates, and certificates
# are a problem you can only have on a real device.
#
# Nothing here needs a team, a provisioning profile, a paid account or a phone.

set -uo pipefail

cd "$(dirname "$0")"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
failures=0

step()  { printf '\n%s==> %s%s\n' "$BOLD" "$1" "$OFF"; }
ok()    { printf '%s    ok%s  %s\n' "$GREEN" "$OFF" "$1"; }
warn()  { printf '%s    --%s  %s\n' "$YELLOW" "$OFF" "$1"; }
fail()  { printf '%s  FAIL%s  %s\n' "$RED" "$OFF" "$1"; failures=$((failures + 1)); }

# ---------------------------------------------------------------------------
# 1. The domain, with no Xcode involved at all.
# ---------------------------------------------------------------------------
# RideGuardCore imports Foundation and nothing else, which is what makes this
# possible — and is why that rule is worth defending. These same tests run on
# Linux, so the maths can be checked by anyone, on anything, in about a second.

step "Domain suite (swift test — no Xcode, no simulator, no signing)"
if command -v swift >/dev/null 2>&1; then
    if swift test 2>&1 | tail -40; then
        ok "domain green"
    else
        fail "domain suite — fix this before touching Xcode; nothing downstream can be right while the maths is wrong"
    fi
else
    fail "no swift on PATH (install Xcode command line tools: xcode-select --install)"
fi

# ---------------------------------------------------------------------------
# 2. Generate the project.
# ---------------------------------------------------------------------------
# There is no .xcodeproj in git on purpose; project.yml is the source of truth.

step "Generate RideGuard.xcodeproj from project.yml"
if ! command -v xcodegen >/dev/null 2>&1; then
    fail "xcodegen not installed — run: brew install xcodegen"
else
    if xcodegen generate; then
        ok "project generated"
    else
        fail "xcodegen — project.yml is malformed"
    fi
fi

# ---------------------------------------------------------------------------
# 3. Compile every target, unsigned, for the Simulator.
# ---------------------------------------------------------------------------
# CODE_SIGNING_ALLOWED=NO is the whole trick. The app target depends on all
# three extensions, so building it builds them, and any missing file, wrong
# API or unresolved symbol surfaces here rather than after an hour of
# provisioning work.
#
# The Simulator cannot actually RUN the two things this app is about —
# ReplayKit will not broadcast and Picture-in-Picture is unavailable — but it
# compiles them identically, which is what this stage is for.

step "Build all targets for the Simulator, unsigned"
if ! command -v xcodebuild >/dev/null 2>&1; then
    fail "no xcodebuild — install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app"
elif [ ! -d RideGuard.xcodeproj ]; then
    warn "skipped — no project to build"
else
    log=$(mktemp)
    if xcodebuild \
        -project RideGuard.xcodeproj \
        -scheme RideGuard \
        -sdk iphonesimulator \
        -destination 'generic/platform=iOS Simulator' \
        -configuration Debug \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        build > "$log" 2>&1
    then
        ok "all targets compile"
    else
        fail "compile — first errors follow"
        grep -E "error:|warning: no rule|cannot find|Undefined symbol" "$log" | head -30
        printf '    full log: %s\n' "$log"
    fi
fi

# ---------------------------------------------------------------------------
# 3b. Drive the real UI on a booted Simulator.
# ---------------------------------------------------------------------------
# The one stage here that needs a running device, and the only one that catches
# the class of bug this app has now shipped twice: a keyboard that cannot be
# dismissed, and then two Done buttons in the "fix" for it. Both compiled
# cleanly and passed every unit test above.
#
# Skipped rather than failed when no Simulator is available, so this script
# still does something useful on a machine without one.

step "Drive the UI on a Simulator (keyboard, focus, chrome)"
sim_udid=$(xcrun simctl list devices available 2>/dev/null \
           | grep -E '^\s+iPhone' | head -1 \
           | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/') || true

if [ -z "${sim_udid:-}" ]; then
    warn "skipped — no iOS Simulator available"
elif [ ! -d RideGuard.xcodeproj ]; then
    warn "skipped — no project to test"
else
    log=$(mktemp)
    if xcodebuild \
        -project RideGuard.xcodeproj \
        -scheme RideGuard \
        -sdk iphonesimulator \
        -destination "id=$sim_udid" \
        CODE_SIGNING_ALLOWED=NO \
        test -only-testing:RideGuardUITests > "$log" 2>&1
    then
        ok "keyboard can be dismissed, one Done button, nothing hidden under it"
    else
        fail "UI tests — failing assertions follow"
        grep -E "error:.*XCTAssert|Test Case.*failed" "$log" | head -20
        printf '    full log: %s\n' "$log"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Things that are silently fatal at runtime and free to check here.
# ---------------------------------------------------------------------------
# Each of these fails by doing NOTHING on a device — no crash, no log line —
# which is the most expensive kind of bug to chase on a phone in a car.

step "Configuration that fails silently on device"

group_id=$(grep -o 'group\.[a-zA-Z0-9._]*' RideGuard/Core/Live/LiveVerdict.swift | head -1)
if [ -z "$group_id" ]; then
    fail "could not find the App Group identifier in LiveVerdict.swift"
else
    mismatched=0
    for f in RideGuard/RideGuard.entitlements \
             RideGuardBroadcast/RideGuardBroadcast.entitlements \
             RideGuard/App/Persistence.swift; do
        if ! grep -q "$group_id" "$f"; then
            fail "$f does not mention $group_id — the extension would write where the app cannot read, and the HUD would just never update"
            mismatched=1
        fi
    done
    [ "$mismatched" -eq 0 ] && ok "App Group $group_id agrees across the app, the broadcast extension and Persistence"
fi

# The principal class is resolved by NAME through the Objective-C runtime. Get
# it wrong and the broadcast starts, no frames are ever delivered, and nothing
# anywhere says why.
if grep -q 'PRODUCT_MODULE_NAME).SampleHandler' RideGuardBroadcast/Info.plist \
   && grep -q 'class SampleHandler' RideGuardBroadcast/SampleHandler.swift; then
    ok "broadcast principal class resolves to a class that exists"
else
    fail "RideGuardBroadcast principal class and SampleHandler disagree"
fi

if grep -q 'RPBroadcastProcessModeSampleBuffer' RideGuardBroadcast/Info.plist; then
    ok "broadcast delivers sample buffers, not a finished movie"
else
    fail "RPBroadcastProcessMode is not SampleBuffer — frames would arrive only after the ride is over"
fi

# PiP is what keeps the HUD on screen, and it only survives backgrounding while
# the process does. Without the audio background mode the window dies the
# instant the driver switches to Bolt — i.e. always.
if grep -A3 'UIBackgroundModes' RideGuard/Info.plist | grep -q '<string>audio</string>'; then
    ok "app declares background audio (required for the PiP overlay to survive)"
else
    fail "UIBackgroundModes is missing 'audio' — the HUD would vanish on switching apps"
fi

# The picker has to point at the broadcast extension's bundle id, not the app's.
picker_target=$(grep -o '"[A-Za-z0-9.]*\.broadcast"' RideGuard/Overlay/BroadcastPickerButton.swift | head -1 | tr -d '"')
broadcast_id=$(grep -o 'PRODUCT_BUNDLE_IDENTIFIER: .*\.broadcast' project.yml | head -1 | sed 's/.*: //')
if [ -n "$picker_target" ] && [ "$picker_target" = "$broadcast_id" ]; then
    ok "broadcast picker points at $picker_target"
else
    fail "BroadcastPickerButton's preferredExtension does not match the broadcast target's bundle id — the picker would list every screen recorder except ours"
fi

# ---------------------------------------------------------------------------

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf '%s%sEverything that can be checked without an Apple account passed.%s\n' "$GREEN" "$BOLD" "$OFF"
    printf 'Next: open RideGuard.xcodeproj, set Team on all four signable targets,\n'
    printf 'and enable the App Group on the app and the broadcast extension. See README.md.\n'
    exit 0
fi

printf '%s%s%d check(s) failed.%s\n' "$RED" "$BOLD" "$failures" "$OFF"
exit 1

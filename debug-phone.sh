#!/usr/bin/env bash
#
# Connect to the phone over Wi-Fi and stream RideGuard's logs to this terminal.
#
#   ./debug-phone.sh pair 192.168.1.129:37somethin 123456   # once, first time
#   ./debug-phone.sh connect 192.168.1.129:5555             # each reboot
#   ./debug-phone.sh logs                                   # follow the logs
#   ./debug-phone.sh install                                # push the latest build
#   ./debug-phone.sh crash                                  # just the crash traces
#   ./debug-phone.sh status                                 # what's connected
#
# No USB cable required — Android 11+ supports wireless debugging natively.

set -uo pipefail

ADB="${ANDROID_HOME:-$HOME/Android/Sdk}/platform-tools/adb"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APK="$ROOT/android/app/build/outputs/apk/sideload/debug/app-sideload-debug.apk"

# Both the app id and the raw tags — a crash in the accessibility service is
# sometimes attributed to the system process rather than to us, so filtering on
# the package alone can hide exactly the trace we need.
TAGS="RideGuardA11y:V OverlayHost:V OfferRecorder:V ProjectionOcrSource:V ProjectionCapture:V"
APP_ID="com.rideguard.sideload.debug"

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

case "${1:-help}" in

  pair)
    # The PAIRING port is NOT the connection port. Android shows the pairing
    # host:port inside the "Pair device with pairing code" dialog, and a
    # different port on the main Wireless debugging screen. Both are needed.
    [[ $# -ge 2 ]] || { echo "usage: $0 pair <ip:pairing-port> [code]"; exit 1; }
    if [[ $# -ge 3 ]]; then
      "$ADB" pair "$2" "$3"
    else
      "$ADB" pair "$2"
    fi
    echo
    echo "Now run:  $0 connect <ip:port-from-the-main-wireless-debugging-screen>"
    ;;

  connect)
    [[ $# -ge 2 ]] || { echo "usage: $0 connect <ip:port>"; exit 1; }
    "$ADB" connect "$2"
    "$ADB" devices -l
    ;;

  status)
    "$ADB" devices -l
    echo
    echo "Installed RideGuard packages:"
    "$ADB" shell pm list packages 2>/dev/null | grep -i rideguard | sed 's/^/  /' || echo "  none"
    echo
    echo "Accessibility services currently enabled:"
    "$ADB" shell settings get secure enabled_accessibility_services 2>/dev/null | tr ':' '\n' | sed 's/^/  /'
    echo
    echo "Accessibility master switch:"
    "$ADB" shell settings get secure accessibility_enabled 2>/dev/null | sed 's/^/  /'
    ;;

  install)
    [[ -f "$APK" ]] || { echo "APK not built. Run: cd android && ./gradlew :app:assembleSideloadDebug"; exit 1; }
    echo "Installing $(du -h "$APK" | cut -f1)…"
    "$ADB" install -r -d "$APK"
    ;;

  enable)
    # Turning the service on from here skips the "restricted setting" block
    # entirely, because adb is a trusted installer path.
    SVC="$APP_ID/com.rideguard.service.RideGuardAccessibilityService"
    echo "Enabling $SVC"
    "$ADB" shell settings put secure enabled_accessibility_services "$SVC"
    "$ADB" shell settings put secure accessibility_enabled 1
    echo "Done. Verify with: $0 status"
    ;;

  logs)
    "$ADB" logcat -c 2>/dev/null
    echo "Streaming RideGuard logs — Ctrl-C to stop."
    echo "─────────────────────────────────────────────"
    # shellcheck disable=SC2086
    "$ADB" logcat -v time $TAGS AndroidRuntime:E System.err:W *:S
    ;;

  crash)
    echo "Recent crashes (most recent last):"
    "$ADB" logcat -d -b crash -v time 2>/dev/null | tail -80
    echo
    echo "─── fatal exceptions in the main buffer ───"
    "$ADB" logcat -d -v time 2>/dev/null | grep -A 30 -iE "FATAL EXCEPTION|AndroidRuntime.*rideguard" | tail -80
    ;;

  all)
    # Everything from our process, unfiltered. Noisy but occasionally the only
    # way to catch something logged under a tag we did not anticipate.
    PID="$("$ADB" shell pidof "$APP_ID" 2>/dev/null | tr -d '\r')"
    if [[ -n "$PID" ]]; then
      echo "Following pid $PID ($APP_ID)"
      "$ADB" logcat -v time --pid="$PID"
    else
      echo "$APP_ID is not running. Showing anything mentioning rideguard:"
      "$ADB" logcat -v time | grep -i --line-buffered rideguard
    fi
    ;;

  *)
    usage
    ;;
esac

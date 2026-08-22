#!/bin/bash
#
# Put the current build on your phone, over Wi-Fi, by scanning a QR code.
#
# Builds the sideload release APK, serves it from this Mac on the local
# network, and prints a QR code pointing at it. Scan it with the phone's
# camera, tap the link, install.
#
# Both devices have to be on the SAME Wi-Fi. The server only exists while this
# window is open — close it and the download link dies with it, which is the
# point: nothing is left listening on your network afterwards.

set -euo pipefail

ANDROID_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=8787
SERVE_DIR="/tmp/rideguard-apk"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '\033[32m  ok\033[0m  %s\n' "$1"; }
warn() { printf '\033[33m  !!\033[0m  %s\n' "$1"; }
die()  { printf '\n\033[31mfailed:\033[0m %s\n\n' "$1" >&2; exit 1; }

# --- Toolchain --------------------------------------------------------------
#
# Resolved rather than inherited: a double-clicked .command gets a login shell
# with none of the exports a terminal session picks up.

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
export PATH="$JAVA_HOME/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

command -v qrencode >/dev/null 2>&1 || die "qrencode is not installed (brew install qrencode)"

# --- Which address the phone should use -------------------------------------
#
# Whatever this Mac's address is on the Wi-Fi it is actually on. Hard-coding
# one would break the first time you moved between home and anywhere else.

ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
[ -n "$ip" ] || die "this Mac is not on Wi-Fi — the phone has no way to reach it"

# --- Build ------------------------------------------------------------------

bold "==> Building the release APK"
cd "$ANDROID_DIR"
./gradlew :app:assembleSideloadRelease -q >/dev/null 2>&1 \
    || die "the build failed — run ./gradlew :app:assembleSideloadRelease to see why"

apk=$(find app/build/outputs/apk/sideload/release -name '*.apk' | head -1)
[ -n "$apk" ] || die "the build produced no APK"
ok "built $(basename "$apk") ($(du -h "$apk" | cut -f1))"

if [ ! -f "$HOME/.rideguard/keystore.properties" ]; then
    warn "no release keystore, so this is DEBUG-SIGNED"
    printf '      If RideGuard is already on the phone signed with another key,\n'
    printf '      Android will refuse to replace it — uninstall it there first.\n'
fi

# --- Serve ------------------------------------------------------------------
#
# A landing page rather than a bare .apk link, because scanning straight into
# a file download gives no confirmation of what you are about to install, and
# Chrome on Android is happier following a normal link than a QR to a binary.

rm -rf "$SERVE_DIR"
mkdir -p "$SERVE_DIR"
cp "$apk" "$SERVE_DIR/rideguard.apk"

built_at=$(date '+%d %b %Y, %H:%M')
version=$(grep -m1 'versionName = ' app/build.gradle.kts | sed 's/.*"\(.*\)".*/\1/')
git_rev=$(git -C "$ANDROID_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)

cat > "$SERVE_DIR/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>RideGuard</title>
<style>
  body { background:#0F1114; color:#F5F7FA; font:16px/1.5 -apple-system,Roboto,sans-serif;
         margin:0; padding:32px 24px; }
  h1 { font-size:28px; margin:0 0 4px; }
  p  { color:#9AA4B2; margin:0 0 20px; }
  a.btn { display:block; background:#16A34A; color:#fff; text-decoration:none;
          text-align:center; font-weight:700; padding:18px; border-radius:12px;
          margin:28px 0; }
  ol { color:#9AA4B2; padding-left:20px; }
  code { color:#F5F7FA; }
</style>
<h1>RideGuard</h1>
<p>$version &middot; $git_rev &middot; built $built_at</p>
<a class="btn" href="rideguard.apk">Download and install</a>
<ol>
  <li>Tap the button. Android will warn you it is from an unknown source &mdash;
      allow it for your browser, once.</li>
  <li>Open RideGuard and switch on <b>Offer reader</b> under Accessibility.</li>
  <li>Allow background running, or Android kills it mid-shift.</li>
</ol>
HTML

url="http://$ip:$PORT/"

bold "==> Scan this with your phone's camera"
printf '\n'
qrencode -t ANSIUTF8 -m 2 "$url"
printf '\n    %s\n' "$url"

# A PNG too, for scanning off a second screen or sending to someone.
qrencode -o "$SERVE_DIR/qr.png" -s 10 -m 2 "$url"
ok "also saved to $SERVE_DIR/qr.png"

bold "Serving. Close this window when the phone has it."
printf '  Both devices must be on the same Wi-Fi.\n\n'

cd "$SERVE_DIR"
# Foreground on purpose: this process IS the lifetime of the download link.
exec python3 -m http.server "$PORT" --bind 0.0.0.0

#!/usr/bin/env bash
#
# Collect every built APK into dist/ and serve them over the local network so
# the phone can download them straight from its browser.
#
#   ./serve-apks.sh          # collect + serve on port 8000
#   ./serve-apks.sh 9000     # ...on a different port
#
# The phone must be on the SAME Wi-Fi as this laptop. If nothing loads, the
# usual culprit is the laptop firewall, not the script.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"
PORT="${1:-8000}"

rm -rf "$DIST"
mkdir -p "$DIST"

collect() {
  local src="$1" dest="$2"
  if [[ -f "$src" ]]; then
    cp "$src" "$DIST/$dest"
    echo "  ✔ $dest  ($(du -h "$src" | cut -f1))"
  else
    echo "  ✘ $dest  — not built yet"
  fi
}

echo "Collecting APKs…"
collect "$ROOT/android/app/build/outputs/apk/sideload/debug/app-sideload-debug.apk" \
        "rideguard-sideload.apk"
collect "$ROOT/android/app/build/outputs/apk/play/debug/app-play-debug.apk" \
        "rideguard-play.apk"

# RELEASE, not debug, for the mock — and this matters.
#
# A React Native *debug* APK does not contain the JavaScript bundle. It fetches
# it from a Metro dev server at launch, so it only runs while `npx expo start`
# is up on this laptop and the phone can reach it. Useless for handing someone
# an APK to install.
#
# The release build embeds the bundle, so it is genuinely standalone. Expo's
# generated build.gradle signs release with the debug keystore, so no keystore
# setup is needed. It is also built arm64-only, which takes it from 216 MB to
# roughly 40 MB.
collect "$ROOT/mock/android/app/build/outputs/apk/release/app-release.apk" \
        "rideguard-mock.apk"

# Build the landing page from whatever actually got collected.
{
  cat <<'HTML'
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>RideGuard — downloads</title>
<script>
  // The download links below are relative, which is what makes this page work
  // unchanged whether it is served at the root (plain LAN, http://IP:8000/) or
  // under a path prefix (Tailscale Funnel, https://host/apks/).
  //
  // But relative links only resolve correctly when the page URL ends in a
  // slash: at "/apks" the browser treats "/" as the base and a tap would land
  // on "/rideguard-mock.apk" — a different service entirely. Normalising here
  // means the URL can be typed either way.
  if (!location.pathname.endsWith('/')) {
    location.replace(location.pathname + '/' + location.search + location.hash);
  }
</script>
<style>
  :root { color-scheme: dark; }
  body { margin:0; padding:24px; background:#0F1114; color:#F5F7FA;
         font:16px/1.5 system-ui,-apple-system,sans-serif; }
  h1 { font-size:24px; margin:0 0 4px; }
  p.sub { color:#9AA4B2; font-size:14px; margin:0 0 24px; }
  a.card { display:block; text-decoration:none; background:#161A1F;
           border:1px solid #2A323B; border-radius:14px;
           padding:16px; margin-bottom:12px; }
  a.card:active { background:#1E242B; }
  .name { color:#F5F7FA; font-weight:700; font-size:17px; }
  .desc { color:#9AA4B2; font-size:13px; margin-top:4px; }
  .size { color:#16A34A; font-size:12px; font-weight:700; margin-top:6px; }
  ol { color:#9AA4B2; font-size:13px; padding-left:20px; }
  li { margin-bottom:6px; }
  code { background:#1E242B; padding:1px 5px; border-radius:4px; font-size:12px; }
</style>
<h1>RideGuard</h1>
<p class="sub">Tap to download, then open the file to install.</p>
HTML

  card() {
    local file="$1" name="$2" desc="$3"
    [[ -f "$DIST/$file" ]] || return 0
    printf '<a class="card" href="%s"><div class="name">%s</div><div class="desc">%s</div><div class="size">%s</div></a>\n' \
      "$file" "$name" "$desc" "$(du -h "$DIST/$file" | cut -f1)"
  }

  card "rideguard-sideload.apk" "RideGuard (sideload)" \
       "The one you want. Reads offers via the accessibility service."
  card "rideguard-mock.apk" "Mock Bolt / Uber" \
       "Fake offer screens for testing without waiting for a real ride. arm64 only."
  card "rideguard-play.apk" "RideGuard (play / OCR)" \
       "Alternative reader using screen capture. Only if the sideload build misbehaves."

  cat <<'HTML'
<h1 style="font-size:17px;margin-top:28px">Install order</h1>
<ol>
  <li>Allow <em>Install unknown apps</em> for your browser when prompted.</li>
  <li>Install <strong>RideGuard (sideload)</strong>, open it, finish setup.</li>
  <li>Enable <code>Settings → Accessibility → RideGuard offer reader</code>.</li>
  <li>Install <strong>Mock Bolt / Uber</strong>, fire a preset, watch the HUD.</li>
</ol>
HTML
} > "$DIST/index.html"

# If a phone is already plugged in with USB debugging on, that is strictly
# faster and less fiddly than downloading through a browser — so offer it.
ADB="${ANDROID_HOME:-$HOME/Android/Sdk}/platform-tools/adb"
if [[ -x "$ADB" ]] && [[ -n "$("$ADB" devices | awk 'NR>1 && $2=="device"')" ]]; then
  echo
  echo "A device is connected over USB. Installing directly…"
  for apk in rideguard-sideload.apk rideguard-mock.apk; do
    [[ -f "$DIST/$apk" ]] || continue
    # -r reinstalls over an existing copy; -d allows a downgrade, which saves
    # an uninstall dance when reflashing an older build during testing.
    if "$ADB" install -r -d "$DIST/$apk" >/dev/null 2>&1; then
      echo "  ✔ installed $apk"
    else
      echo "  ✘ $apk failed — falling back to the browser download below"
    fi
  done
  echo
fi

# Pick the address the phone can actually reach.
#
# `hostname -I` is not good enough here: this machine also has a libvirt bridge
# (192.168.122.1), a Tailscale address (100.x) and possibly docker0, all of
# which look like plausible LAN IPs and none of which a phone on the Wi-Fi can
# route to. The source address of the default route is the one that is really
# on the local network.
IP="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)"

# Fallback: first IPv4 on a physical interface, virtual ones excluded by name.
if [[ -z "${IP:-}" ]]; then
  IP="$(ip -4 -o addr show 2>/dev/null \
        | grep -vE '\b(lo|virbr[0-9]*|docker[0-9]*|tailscale[0-9]*|veth[^ ]*|br-[^ ]*)\b' \
        | awk '{print $4}' | cut -d/ -f1 | head -1)"
fi

echo "─────────────────────────────────────────────"
echo "  On the phone's browser, open:"
echo
echo "      http://$IP:$PORT"
echo
echo "  (phone must be on the same network as this laptop)"
echo "  Ctrl-C to stop."
echo "─────────────────────────────────────────────"
echo

# Show the alternatives too — if the address above does not load, one of these
# usually will, and it saves a round of guessing.
OTHERS="$(ip -4 -o addr show 2>/dev/null \
          | grep -vE '\blo\b' | awk '{print $4}' | cut -d/ -f1 | grep -v "^$IP$" || true)"
if [[ -n "$OTHERS" ]]; then
  echo "  If that does not load, try:"
  while read -r alt; do [[ -n "$alt" ]] && echo "      http://$alt:$PORT"; done <<< "$OTHERS"
  echo
fi

cd "$DIST"
exec python3 -m http.server "$PORT" --bind 0.0.0.0

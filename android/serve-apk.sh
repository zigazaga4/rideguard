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

# An older run of this script, still open in another window, would keep
# answering on this port and hand the phone yesterday's build. The newest
# invocation wins.
if lsof -ti "tcp:$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    lsof -ti "tcp:$PORT" -sTCP:LISTEN | xargs kill 2>/dev/null || true
    sleep 1
    warn "stopped an older server that was still holding port $PORT"
fi

bold "==> Building the release APK"
cd "$ANDROID_DIR"

OUT_DIR="app/build/outputs/apk/sideload/release"

# Deleted BEFORE the build, not after, and this is the whole guarantee that
# what gets served is what was just built. Gradle leaves the previous APK in
# place when a build fails, and it does not clean out APKs whose name changed
# with the version — so "an APK exists here" proved nothing. Now the file's
# existence IS the proof the build produced it. Only the packaging step re-runs;
# compilation stays incremental.
rm -rf "$OUT_DIR"

./gradlew :app:assembleSideloadRelease -q >/dev/null 2>&1 \
    || die "the build failed — run ./gradlew :app:assembleSideloadRelease to see why"

# AGP writes down exactly which file it produced. Trust that rather than
# globbing: `find ... | head -1` returns directory order, not the newest, so it
# picked whichever APK the filesystem happened to list first.
apk=$(python3 - "$OUT_DIR/output-metadata.json" <<'PYEOF' 2>/dev/null || true
import json, os, sys
meta = sys.argv[1]
with open(meta) as fh:
    data = json.load(fh)
print(os.path.join(os.path.dirname(meta), data["elements"][0]["outputFile"]))
PYEOF
)

# Fall back to newest-by-mtime if AGP ever changes that file's shape.
if [ -z "${apk:-}" ] || [ ! -f "$apk" ]; then
    apk=$(find "$OUT_DIR" -name '*.apk' -print0 2>/dev/null \
          | xargs -0 ls -t 2>/dev/null | head -1) || true
fi
[ -n "${apk:-}" ] && [ -f "$apk" ] || die "the build produced no APK"
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

built_at=$(date '+%d %b %Y, %H:%M')
stamp=$(date '+%H%M%S')
version=$(grep -m1 'versionName = ' app/build.gradle.kts | sed 's/.*"\(.*\)".*/\1/')
git_rev=$(git -C "$ANDROID_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)

# A dirty tree is the normal case while working, but it means the git rev on
# the page does NOT describe what is in the APK. Say so rather than implying a
# clean build.
if ! git -C "$ANDROID_DIR" diff --quiet HEAD 2>/dev/null; then
    git_rev="$git_rev+edits"
fi

# The filename changes every run, on purpose. Served under one fixed name, the
# phone's browser is entitled to reuse the copy it already downloaded — you
# scan, tap install, and get the previous build with nothing on screen saying
# so. A URL that has never been requested before cannot be answered from a
# cache, and the name doubles as a record of which build is on the phone.
apk_name="rideguard-$version-$git_rev-$stamp.apk"
cp "$apk" "$SERVE_DIR/$apk_name"

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
<a class="btn" href="$apk_name">Download and install</a>
<ol>
  <li>Tap the button. Android will warn you it is from an unknown source &mdash;
      allow it for your browser, once.</li>
  <li>Open RideGuard and switch on <b>Offer reader</b> under Accessibility.</li>
  <li>Allow background running, or Android kills it mid-shift.</li>
</ol>
HTML

# The stamp is not decoration. A phone that already holds the landing page in
# its cache will happily re-render it — including its download link, which
# names a file this run does not have. That produced a real 404 on a real
# phone. A URL never requested before cannot come out of a cache.
url="http://$ip:$PORT/?b=$stamp"

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

# python3 -m http.server would do, except it sends no cache directives at all,
# which leaves the landing page itself cacheable — you would reload it and see
# the old build's download link. Same server, plus no-store.
#
# Foreground on purpose: this process IS the lifetime of the download link.
cat > server.py <<'PYEOF'
import functools, glob, http.server, os, sys

# The only APK here. The serve directory is rebuilt from scratch each run, so
# there is never a second one to confuse this with.
APK = os.path.basename(glob.glob("*.apk")[0])


class Handler(http.server.SimpleHTTPRequestHandler):
    def _rewrite(self):
        """Point every .apk request at the build we actually have.

        A phone holding an older landing page asks for the filename that page
        named, which no longer exists because the name carries a timestamp —
        a 404 on a real phone, mid-install. Rewriting beats keeping old names
        around: there is exactly one APK here, so a request for one can only
        mean that one, and answering with a stale binary stays impossible.
        """
        path = self.path.split("?", 1)[0]
        if path.endswith(".apk") and not os.path.isfile("." + path):
            sys.stderr.write("  (rewrote %s -> %s)\n" % (path, APK))
            self.path = "/" + APK

    def do_GET(self):
        self._rewrite()
        super().do_GET()

    def do_HEAD(self):
        self._rewrite()
        super().do_HEAD()

    def end_headers(self):
        self.send_header("Cache-Control", "no-store, must-revalidate")
        self.send_header("Pragma", "no-cache")
        super().end_headers()

    def log_message(self, fmt, *args):
        # One readable line per hit, so you can see the phone actually pull it.
        sys.stderr.write("  %s\n" % (fmt % args))

http.server.test(
    HandlerClass=functools.partial(Handler, directory="."),
    ServerClass=http.server.ThreadingHTTPServer,
    port=int(sys.argv[1]),
    bind="0.0.0.0",
)
PYEOF
exec python3 server.py "$PORT"

#!/usr/bin/env bash
#
# Publish a RideGuard release that the installed app will offer to install itself.
#
#   ./release.sh 1.1.0 "Bolt fares are read as net now."
#
# What it does, in order:
#   1. bumps versionCode/versionName in android/app/build.gradle.kts
#   2. builds the signed sideload release APK
#   3. creates a GitHub release and uploads the APK to it
#   4. writes updates/latest.json — the file every installed app polls
#   5. commits and pushes
#
# Step 4 is the one that actually ships the update. Steps 1-3 just put a file
# on the internet; nothing on anyone's phone knows about it until the manifest
# points at it. That ordering is deliberate: the APK is uploaded and verified
# BEFORE the manifest advertises it, so there is never a window where a phone
# is told to download something that is not there yet.

set -euo pipefail

cd "$(dirname "$0")"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; DIM=$'\e[2m'; RST=$'\e[0m'
die() { echo "${RED}error:${RST} $*" >&2; exit 1; }
step() { echo; echo "${GRN}==>${RST} $*"; }

REPO="zigazaga4/rideguard"
GRADLE="android/app/build.gradle.kts"
MANIFEST="updates/latest.json"

VERSION="${1:-}"
NOTES="${2:-}"

[ -n "$VERSION" ] || die "usage: ./release.sh <version> [notes]
       e.g. ./release.sh 1.1.0 \"Bolt fares are read as net now.\""

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.2.3, got '$VERSION'"

# --- preflight -------------------------------------------------------------
# Every one of these has cost someone an hour at some point. Check them all up
# front rather than failing eight minutes into a build.

step "Preflight"

command -v gh >/dev/null || die "gh CLI not installed"
gh auth status >/dev/null 2>&1 || die "gh is not logged in — run: gh auth login"

[ -f "$HOME/.rideguard/keystore.properties" ] \
    || die "no release keystore at ~/.rideguard/keystore.properties

The updater replaces the installed app with this APK, and Android refuses to
replace an app with one signed by a different key. Without the release key the
build falls back to debug signing and every phone will reject the update with
a signature conflict."

KEYSTORE=$(grep '^storeFile=' "$HOME/.rideguard/keystore.properties" | cut -d= -f2-)
[ -f "$KEYSTORE" ] || die "keystore.properties points at $KEYSTORE, which does not exist"

[ -z "$(git status --porcelain)" ] \
    || die "working tree is dirty — commit or stash first, so the tag matches what shipped"

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    die "tag v$VERSION already exists"
fi

export JAVA_HOME="${JAVA_HOME:-/home/leo/jdk}"
export ANDROID_HOME="${ANDROID_HOME:-/home/leo/Android/Sdk}"
[ -x "$JAVA_HOME/bin/java" ] || die "no JDK at JAVA_HOME=$JAVA_HOME"

CURRENT_CODE=$(grep -oP 'versionCode\s*=\s*\K[0-9]+' "$GRADLE" | head -1)
[ -n "$CURRENT_CODE" ] || die "could not read versionCode out of $GRADLE"
NEW_CODE=$((CURRENT_CODE + 1))

echo "  repo          $REPO"
echo "  version       $VERSION"
echo "  versionCode   $CURRENT_CODE -> $NEW_CODE"
echo "  keystore      $KEYSTORE"

# --- 1. bump ---------------------------------------------------------------

step "Bumping version"
sed -i "0,/versionCode = $CURRENT_CODE/s//versionCode = $NEW_CODE/" "$GRADLE"
sed -i "0,/versionName = \".*\"/s//versionName = \"$VERSION\"/" "$GRADLE"
grep -nE 'versionCode|versionName' "$GRADLE" | head -2 | sed 's/^/  /'

# If anything below fails, leave the tree as we found it rather than stranding
# a bumped version that was never released.
restore_on_failure() {
    echo "${YLW}rolling back the version bump${RST}" >&2
    git checkout -- "$GRADLE" 2>/dev/null || true
}
trap restore_on_failure ERR

# --- 2. build --------------------------------------------------------------

step "Building signed release APK  ${DIM}(several minutes)${RST}"
(
    cd android
    # --no-daemon: this machine runs close to its memory limit and a lingering
    # Gradle daemon is the difference between a build and an OOM kill.
    ./gradlew :app:assembleSideloadRelease --no-daemon --max-workers=2
)

APK="android/app/build/outputs/apk/sideload/release/app-sideload-release.apk"
[ -f "$APK" ] || die "expected APK at $APK, not found"

# Prove it is signed with the release key and not the debug fallback. A
# debug-signed release is the failure this whole script exists to prevent, and
# it is completely invisible until a phone rejects the update.
APKSIGNER=$(find "$ANDROID_HOME/build-tools" -name apksigner -type f 2>/dev/null | sort -V | tail -1)
if [ -n "$APKSIGNER" ]; then
    APK_SHA=$("$APKSIGNER" verify --print-certs "$APK" 2>/dev/null \
        | grep -i 'SHA-256 digest' | head -1 | awk '{print $NF}')
    KEY_SHA=$("$JAVA_HOME/bin/keytool" -list -v \
        -keystore "$KEYSTORE" \
        -storepass "$(grep '^storePassword=' "$HOME/.rideguard/keystore.properties" | cut -d= -f2-)" \
        -alias "$(grep '^keyAlias=' "$HOME/.rideguard/keystore.properties" | cut -d= -f2-)" 2>/dev/null \
        | grep 'SHA256:' | head -1 | awk '{print $2}' | tr -d ':' | tr 'A-Z' 'a-z')
    if [ -n "$APK_SHA" ] && [ -n "$KEY_SHA" ] && [ "$APK_SHA" != "$KEY_SHA" ]; then
        die "APK is signed with $APK_SHA but the release key is $KEY_SHA — refusing to publish"
    fi
    echo "  signing cert  ${APK_SHA:-unverified}"
else
    echo "  ${YLW}apksigner not found; skipping signature check${RST}"
fi

SHA256=$(sha256sum "$APK" | cut -d' ' -f1)
SIZE=$(stat -c%s "$APK")
MIN_SDK=$(grep -oP 'minSdk\s*=\s*\K[0-9]+' "$GRADLE" | head -1)

echo "  size          $((SIZE / 1024 / 1024)) MB"
echo "  sha256        $SHA256"

ASSET="rideguard-$VERSION-sideload.apk"
cp "$APK" "/tmp/$ASSET"

# --- 3. GitHub release -----------------------------------------------------

step "Creating GitHub release v$VERSION"
git tag -a "v$VERSION" -m "RideGuard $VERSION"

gh release create "v$VERSION" \
    --repo "$REPO" \
    --title "RideGuard $VERSION" \
    --notes "${NOTES:-No release notes.}" \
    "/tmp/$ASSET"

DOWNLOAD_URL="https://github.com/$REPO/releases/download/v$VERSION/$ASSET"

# Confirm the asset is actually fetchable before any phone is told to fetch it.
step "Verifying the asset is live"
HTTP=$(curl -sSL -o /dev/null -w '%{http_code}' "$DOWNLOAD_URL")
[ "$HTTP" = "200" ] || die "release asset returned HTTP $HTTP at $DOWNLOAD_URL"
echo "  $DOWNLOAD_URL -> 200"

# --- 4. the manifest — this is what ships the update -----------------------

step "Publishing update manifest"
mkdir -p updates

# jq builds this rather than a heredoc so release notes containing quotes,
# newlines or backslashes cannot produce invalid JSON — which would break the
# updater for every installed copy at once.
jq -n \
    --argjson code "$NEW_CODE" \
    --arg version "$VERSION" \
    --arg url "$DOWNLOAD_URL" \
    --arg sha "$SHA256" \
    --argjson size "$SIZE" \
    --argjson minsdk "${MIN_SDK:-26}" \
    --arg notes "${NOTES:-}" \
    --arg published "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
        schemaVersion: 1,
        publishedAt: $published,
        notes: $notes,
        mandatory: false,
        android: {
            versionCode: $code,
            versionName: $version,
            url: $url,
            sha256: $sha,
            sizeBytes: $size,
            minSdk: $minsdk
        }
    }' > "$MANIFEST"

jq . "$MANIFEST" | sed 's/^/  /'

# --- 5. commit and push ----------------------------------------------------

trap - ERR

step "Committing and pushing"
git add "$GRADLE" "$MANIFEST"
git commit -q -m "Release $VERSION

$( [ -n "$NOTES" ] && echo "$NOTES" || echo "No release notes." )

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push -q origin main
git push -q origin "v$VERSION"

echo
echo "${GRN}Published RideGuard $VERSION (build $NEW_CODE).${RST}"
echo
echo "Installed apps will see it within about five minutes — raw.githubusercontent.com"
echo "is CDN-cached, so it is not instant."
echo
echo "  release   https://github.com/$REPO/releases/tag/v$VERSION"
echo "  manifest  https://raw.githubusercontent.com/$REPO/main/$MANIFEST"

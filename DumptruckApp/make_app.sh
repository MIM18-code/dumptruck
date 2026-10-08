#!/bin/bash
# Build Dumptruck.app: swift build -> bundle -> icon -> codesign.
#
# Signing: uses the STABLE self-signed identity "Dumptruck Local Signing"
# when present in the login keychain (created 2026-08-21). TCC keys file
# permissions on the code-signing identity; ad-hoc signatures change every
# build, so each rebuild used to re-trigger the hidden "access Documents"
# prompt (the first-inspect 30-45s stall). With the stable identity, grants
# survive rebuilds. Falls back to ad-hoc (with a warning) if the identity
# is ever missing — recreate it per reviews/TRIAGE round 14 notes.
set -euo pipefail
cd "$(dirname "$0")"

SWIFT_BUILD_ARGS=(-c release)
if [ "${DUMPTRUCK_SWIFTPM_DISABLE_SANDBOX:-0}" = "1" ]; then
    SWIFT_BUILD_ARGS+=(--disable-sandbox)
fi
# Stamp the real SDK version into LC_BUILD_VERSION. Under Xcode 27 SwiftPM's
# link step wrote sdk=14.0 (the deployment target) instead of the SDK it
# built against, and macOS draws an app stamped below 26 with the legacy
# flat toolbar (2026-09-15: the look changed between two builds of the same
# source). swiftc alone stamps correctly; the last -platform_version wins.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SWIFT_BUILD_ARGS+=(-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION")
swift build "${SWIFT_BUILD_ARGS[@]}" 2>&1 | tail -3

# The app carries the engine's version. dumptruck/__init__.py is the single
# source of truth; packaging/make_dmg.sh and make_public_dmg.sh read it the
# same way for the DMG filename, so the plist and the DMG name cannot drift.
# The Homebrew formula installs dumptruck/ into libexec before this script runs,
# so fall back to the engine root it passes in when ../dumptruck is gone.
ENGINE_INIT="../dumptruck/__init__.py"
if [ ! -f "$ENGINE_INIT" ] && [ -n "${DUMPTRUCK_ENGINE_ROOT:-}" ]; then
    ENGINE_INIT="$DUMPTRUCK_ENGINE_ROOT/dumptruck/__init__.py"
fi
APP_VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$ENGINE_INIT")"
[ -n "$APP_VERSION" ] || { echo "could not determine engine version from $ENGINE_INIT" >&2; exit 1; }
[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
    || { echo "engine version '$APP_VERSION' is not dotted integers; CFBundleVersion would be rejected" >&2; exit 1; }
# CFBundleVersion must only ever increase: macOS prefers the higher build
# when two copies exist. major*10000 + minor*100 + patch keeps it monotonic
# (0.5.0 -> 500, 0.6.0 -> 600, 1.0.0 -> 10000) and above the hand-set
# build 4 that 0.5.0 first shipped with, without needing git history
# (the public source export has none).
IFS=. read -r V_MAJOR V_MINOR V_PATCH <<< "$APP_VERSION"
V_MINOR=${V_MINOR:-0}; V_PATCH=${V_PATCH:-0}
[ "$V_MINOR" -lt 100 ] && [ "$V_PATCH" -lt 100 ] \
    || { echo "engine version '$APP_VERSION' has a minor or patch >= 100; widen the build-number scheme" >&2; exit 1; }
APP_BUILD=$(( 10#$V_MAJOR * 10000 + 10#$V_MINOR * 100 + 10#$V_PATCH ))

APP="build/Dumptruck.app"

# Serialize the whole publish: two concurrent builds could each see "no
# canonical app", nest one bundle inside the other, and delete the only
# backup (round-15 PR review finding 3). mkdir is the atomic lock; the pid
# file makes it OWNER-AWARE so a killed build (set -e before the trap,
# SIGKILL, power loss) can never strand a lock that aborts every future
# build (round-16 re-verdict: FIX-BROKE-SOMETHING).
LOCK="build/.publish.lock"
mkdir -p build
acquire_lock() {
    if mkdir "$LOCK" 2>/dev/null; then
        echo $$ > "$LOCK/pid"
        return 0
    fi
    local owner
    owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        return 1  # a live build owns it
    fi
    rm -rf "$LOCK"  # stale: owner dead or never recorded
    mkdir "$LOCK" 2>/dev/null && echo $$ > "$LOCK/pid"
}
if ! acquire_lock; then
    echo "another make_app.sh publish is in progress ($LOCK, live pid) — aborting" >&2
    exit 1
fi
# Minimal trap IMMEDIATELY after acquisition — nothing between the lock and
# its guaranteed release may run untrapped (mktemp failure stranded it).
trap 'rm -rf "$LOCK"' EXIT
# A SIGKILLed build can orphan staging dirs its successors' mktemp names
# never match (Kimi K3 review F3) — sweep them here, safely serialized by
# the publish lock we now hold.
rm -rf build/.Dumptruck.app.staging.* 2>/dev/null || true
STAGE="$(mktemp -d "build/.Dumptruck.app.staging.XXXXXX")"
BACKUP="build/.Dumptruck.app.previous.locked"

# Never destroy the last known-good signed app until its replacement has been
# assembled, signed, and independently verified. If the keychain locks or
# codesign fails, the canonical app remains untouched.
cleanup() {
    if [ -d "$BACKUP" ] && [ ! -e "$APP" ]; then
        mv "$BACKUP" "$APP"
    fi
    rm -rf "$STAGE"
    rm -rf "$LOCK"
}
trap cleanup EXIT
rm -rf "$BACKUP"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp .build/release/Dumptruck "$STAGE/Contents/MacOS/Dumptruck"
mkdir -p "$STAGE/Contents/Resources/legal"
for document in LICENSE NOTICE THIRD_PARTY_NOTICES.md; do
    cp "../$document" "$STAGE/Contents/Resources/legal/"
done
cp -R ../LICENSES "$STAGE/Contents/Resources/legal/"

cat > "$STAGE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Dumptruck</string>
    <key>CFBundleIdentifier</key><string>tv.mindinmotion.dumptruck</string>
    <key>CFBundleName</key><string>Dumptruck</string>
    <key>CFBundleDisplayName</key><string>Dumptruck</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleVersion</key><string>$APP_BUILD</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MindInMotion</string>
    <key>NSRemovableVolumesUsageDescription</key><string>Dumptruck reads camera cards and writes verified copies to your backup drives.</string>
    <key>NSDesktopFolderUsageDescription</key><string>Needed only if you pick a Desktop folder as a source or destination.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Needed only if you pick a Documents folder as a source or destination.</string>
    <!-- The Connected shelf drags a selection as this type (ShelfDragPayload
         in SourcesRail.swift). A Transferable content type the bundle does
         not export is logged as undeclared and the drop never decodes, so
         the rails could not take a shelf drag (2026-10-05). -->
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>tv.mindinmotion.dumptruck.shelf-paths</string>
            <key>UTTypeDescription</key><string>Dumptruck shelf selection</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Truck sound effects (start / done / failed), if present
SFX="../assets/sfx"
if [ -d "$SFX" ]; then
    mkdir -p "$STAGE/Contents/Resources/sfx/arcade"
    cp "$SFX"/*.mp3 "$STAGE/Contents/Resources/sfx/" 2>/dev/null || true
    cp "$SFX"/arcade/*.mp3 "$STAGE/Contents/Resources/sfx/arcade/" 2>/dev/null || true
fi

# A packaged app can live outside the checkout that owns its Python engine.
# Homebrew sets this to the Cellar libexec path so the app can find that engine
# after the build tree has gone away.
if [ -n "${DUMPTRUCK_ENGINE_ROOT:-}" ]; then
    if [[ "$DUMPTRUCK_ENGINE_ROOT" != /* || "$DUMPTRUCK_ENGINE_ROOT" == *$'\n'* ]]; then
        echo "DUMPTRUCK_ENGINE_ROOT must be one absolute, single-line path" >&2
        exit 1
    fi
    printf '%s\n' "$DUMPTRUCK_ENGINE_ROOT" > \
        "$STAGE/Contents/Resources/engine_root.txt"
fi

# App icon from the transparent logo, if present
LOGO="../assets/dumptruck_logo_transparent.png"
if [ -f "$LOGO" ]; then
    cp "$LOGO" "$STAGE/Contents/Resources/logo.png"
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
        sips -z $sz $sz "$LOGO" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
        sips -z $((sz*2)) $((sz*2)) "$LOGO" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"
fi

SIGN_ID="Dumptruck Local Signing"
CODESIGN_BIN="${CODESIGN_BIN:-codesign}"
SECURITY_BIN="${SECURITY_BIN:-security}"
IDENTITIES="$("$SECURITY_BIN" find-identity -v -p codesigning 2>/dev/null || true)"
if grep -Fq "$SIGN_ID" <<< "$IDENTITIES"; then
    "$CODESIGN_BIN" --force --deep -s "$SIGN_ID" "$STAGE"
else
    echo "WARNING: '$SIGN_ID' identity not found — ad-hoc signing (TCC will re-prompt every rebuild)" >&2
    "$CODESIGN_BIN" --force --deep -s - "$STAGE"
fi
"$CODESIGN_BIN" --verify --deep --strict --verbose=2 "$STAGE"

if [ -e "$APP" ]; then
    mv "$APP" "$BACKUP"
fi
mv "$STAGE" "$APP"
# Re-verify the CANONICAL bundle before discarding the previous one — a
# concurrent mutation between stage-verify and publish must never leave a
# broken app as the only copy (round-15 PR review finding 3).
if ! "$CODESIGN_BIN" --verify --deep --strict "$APP" 2>/dev/null; then
    echo "post-publish verification FAILED — restoring previous app" >&2
    rm -rf "$APP"
    [ -d "$BACKUP" ] && mv "$BACKUP" "$APP"
    exit 1
fi
rm -rf "$BACKUP"
rm -rf "$LOCK"
trap - EXIT
echo "built: $PWD/$APP"

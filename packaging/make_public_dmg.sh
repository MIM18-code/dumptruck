#!/bin/bash
# Build a self-contained local candidate with retained dependency source and notices.
# DUMPTRUCK_CAMERA_HELPERS=1 includes the private RED and Blackmagic helpers.
# ARRI's downloaded command-line tool is not redistributable under its current EULA.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' dumptruck/__init__.py)"
[ -n "$VERSION" ] || { echo "Cannot determine app version" >&2; exit 1; }
RUNTIME="${DUMPTRUCK_RUNTIME:-}"
if [ -z "$RUNTIME" ] && [ -f packaging/vendor/runtime-path.txt ]; then
    RUNTIME="$(cat packaging/vendor/runtime-path.txt)"
fi
[ -n "$RUNTIME" ] || { echo "Run python3 packaging/prepare_runtime.py first." >&2; exit 1; }
python3 packaging/verify_runtime.py "$RUNTIME"
DumptruckApp/make_app.sh
BUILT_VERSION="$(defaults read "$REPO/DumptruckApp/build/Dumptruck.app/Contents/Info.plist" CFBundleShortVersionString)"
[ "$BUILT_VERSION" = "$VERSION" ] \
    || { echo "app bundle says $BUILT_VERSION but the engine is $VERSION" >&2; exit 1; }
STAGE="$(mktemp -d -t dumptruck-candidate)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Dumptruck.app"
cp -R DumptruckApp/build/Dumptruck.app "$APP"
ENGINE="$APP/Contents/Resources/engine"
cp -R "$RUNTIME" "$ENGINE"
# The manifest describes pre-signing inputs, not final code-signed bytes.
mv "$ENGINE/MANIFEST.json" "$ENGINE/legal/BUILD_INPUT_MANIFEST.json"
mkdir "$ENGINE/dumptruck"
cp dumptruck/*.py "$ENGINE/dumptruck/"
# Reports can resolve artwork relative to their bundled engine root.
cp -R assets "$ENGINE/assets"
# The ARRI runtime joins the public candidate only after ARRI approves the
# Licensed Product (Partner Program agreement, section 3.3). Before that,
# DUMPTRUCK_ARRI_TEST=1 builds the prototype ARRI tests (section 3.2): the
# same bundle, labelled arri-test, for delivery to ARRI only.
ARRI_MODE=excluded
LABEL=candidate
if [ "${DUMPTRUCK_CAMERA_HELPERS:-0}" = "1" ]; then
    if [ "${DUMPTRUCK_ARRI_APPROVED:-0}" = "1" ]; then
        ARRI_MODE=bundled
    elif [ "${DUMPTRUCK_ARRI_TEST:-0}" = "1" ]; then
        ARRI_MODE=test
        LABEL=arri-test
    fi
    DUMPTRUCK_ARRI="$([ "$ARRI_MODE" = excluded ] && echo 0 || echo 1)" \
        python3 packaging/stage_camera_helpers.py "$ENGINE" "$APP/Contents/Resources/legal/cameras"
    cp legal/CAMERA_COMPONENT_TERMS.txt "$STAGE/Camera component terms.txt"
fi
cp LICENSE "$STAGE/Apache License.txt"
source packaging/release_signing.sh
pick_signing_identity
if [ "$DEVELOPER_ID" = "1" ]; then
    SIGNING_NOTE="The app is signed with MindInMotion's Developer ID and notarized by Apple."
else
    SIGNING_NOTE="The app is locally signed, not notarized. This is a review candidate."
fi
case "$ARRI_MODE" in
    bundled) ARRI_NOTE="ARRI metadata and thumbnails use the ARRI Image SDK and ARRI MXF Library
bundled inside the app. Their notices are in Dumptruck.app/Contents/Resources/legal/cameras." ;;
    test) ARRI_NOTE="TEST BUILD FOR ARRI REVIEW ONLY. Not for distribution. It bundles the ARRI
Image SDK and ARRI MXF Library for testing under the ARRI Partner Program." ;;
    *) ARRI_NOTE="ARRI metadata and thumbnails require a separately licensed ARRI Reference
Tool installation. Copying and verification do not require it." ;;
esac
cat > "$STAGE/Read Me.txt" <<TEXT
Dumptruck $VERSION for Apple Silicon Macs

Drag Dumptruck.app into Applications. Python and FFmpeg are included.
$SIGNING_NOTE

Dumptruck's original code and assets are Apache-2.0. Separate camera component
terms apply only when the proprietary helpers are included. The app shows
those terms the first time it opens and uses the helpers only if you agree.
Copying and verification work either way. Other open source components retain their
licenses. FFmpeg's complete source archive and build script are included in
Dumptruck.app/Contents/Resources/engine/legal/ffmpeg.

$ARRI_NOTE
TEXT
( cd "$ENGINE" && ./.venv/bin/python -m dumptruck.cli --version )
# Sign only our executables and the open runtime. Preserve vendor library
# bytes and signatures; RED requires its runtime in original form. ARRI's
# JPEG XS plugin arrives ad-hoc signed, so it alone gets our signature.
sign_code "$ENGINE/python/bin/python3.13"
find "$ENGINE/python/lib" \( -name '*.so' -o -name '*.dylib' \) -print0 | while IFS= read -r -d '' lib; do
    sign_code "$lib"
done
if [ -d "$ENGINE/tools/vendor/arri" ]; then
    find "$ENGINE/tools/vendor/arri" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 | while IFS= read -r -d '' lib; do
        sign_if_no_vendor_signature "$lib"
    done
fi
for executable in "$ENGINE/.venv/bin/ffmpeg" "$ENGINE/.venv/bin/ffprobe"; do
    if [ -f "$executable" ]; then sign_code "$executable"; fi
done
for helper in r3d-probe braw-probe arri-probe; do
    if [ -f "$ENGINE/tools/$helper" ]; then sign_camera_helper "$ENGINE/tools/$helper"; fi
done
sign_code "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p packaging/dist
ln -s /Applications "$STAGE/Applications"
DMG="$REPO/packaging/dist/Dumptruck-$VERSION-arm64-$LABEL-$(date +%Y%m%d-%H%M%S).dmg"
[ ! -e "$DMG" ] || { echo "Refusing to overwrite $DMG" >&2; exit 1; }
hdiutil create -volname Dumptruck -srcfolder "$STAGE" -format UDZO -quiet "$DMG"
notarize_dmg "$DMG"
printf 'Built public %s: %s\n' "$LABEL" "$DMG"
shasum -a 256 "$DMG"

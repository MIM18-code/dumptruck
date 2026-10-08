# Signing and notarization shared by make_dmg.sh and make_public_dmg.sh.
# Source this file; it defines functions and sets nothing until called.
#
# Identity order: DUMPTRUCK_SIGN_IDENTITY, then the first "Developer ID
# Application" identity in the keychain, then "Dumptruck Local Signing",
# then ad-hoc. Only a Developer ID identity gets the hardened runtime and a
# secure timestamp, and only a Developer ID build can be notarized.
#
# Notarization reads credentials from a notarytool keychain profile:
# DUMPTRUCK_NOTARY_PROFILE, else dumptruck-notary, else backlot-notary. The
# credentials belong to the MindInMotion team, not to one app, so Backlot's
# profile serves Dumptruck too. A profile is created once with
#   xcrun notarytool store-credentials dumptruck-notary \
#       --apple-id <account> --team-id <TEAMID>
# The password is typed at that prompt and never appears in these scripts.

RELEASE_SIGNING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_ENTITLEMENTS="$RELEASE_SIGNING_DIR/entitlements/camera-helper.plist"

pick_signing_identity() {
    local identities developer_id
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    developer_id="$(sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' <<< "$identities" | head -1)"
    if [ -n "${DUMPTRUCK_SIGN_IDENTITY:-}" ]; then
        IDENTITY="$DUMPTRUCK_SIGN_IDENTITY"
    elif [ -n "$developer_id" ]; then
        IDENTITY="$developer_id"
    elif grep -Fq "Dumptruck Local Signing" <<< "$identities"; then
        IDENTITY="Dumptruck Local Signing"
    else
        IDENTITY="-"
    fi
    case "$IDENTITY" in
        "Developer ID Application:"*)
            DEVELOPER_ID=1
            SIGN_FLAGS=(--options runtime --timestamp) ;;
        *)
            DEVELOPER_ID=0
            SIGN_FLAGS=() ;;
    esac
    printf 'Signing identity: %s\n' "$IDENTITY"
}

# bash 3.2 treats an empty array as unbound under set -u, hence the guard.
sign_code() {
    codesign --force -s "$IDENTITY" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} "$@"
}

# The camera helpers load RED, Blackmagic and ARRI libraries that keep their
# makers' signatures. Under the hardened runtime, library validation would
# refuse a library from another team, so only the helpers opt out of it.
sign_camera_helper() {
    if [ "$DEVELOPER_ID" = "1" ]; then
        sign_code --entitlements "$HELPER_ENTITLEMENTS" "$1"
    else
        sign_code "$1"
    fi
}

# Vendor libraries keep their makers' Developer ID signatures. Only a file
# with no team identity (ad-hoc or unsigned, like ARRI's JPEG XS plugin) is
# signed with ours, because notarization rejects ad-hoc code.
sign_if_no_vendor_signature() {
    # Capture first: under pipefail, grep -q closing the pipe early can kill
    # codesign with SIGPIPE and read as "unsigned".
    local details
    details="$(codesign -dv "$1" 2>&1 || true)"
    if ! grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$' <<< "$details"; then
        sign_code "$1"
    fi
}

# Sign the DMG, submit it, staple the ticket, and check Gatekeeper accepts
# it. Stapling the DMG lets a first launch pass Gatekeeper offline, which
# matters on set. Skips with a notice when the build is not Developer ID
# signed or DUMPTRUCK_NOTARIZE=0.
notarize_dmg() {
    local dmg="$1" profile="${DUMPTRUCK_NOTARY_PROFILE:-}" result status submission candidate
    if [ "$DEVELOPER_ID" != "1" ]; then
        echo "Not notarized: no Developer ID Application identity in the keychain."
        return 0
    fi
    codesign --force -s "$IDENTITY" --timestamp "$dmg"
    if [ "${DUMPTRUCK_NOTARIZE:-1}" != "1" ]; then
        echo "Not notarized: DUMPTRUCK_NOTARIZE=${DUMPTRUCK_NOTARIZE:-}."
        return 0
    fi
    if [ -z "$profile" ]; then
        for candidate in dumptruck-notary backlot-notary; do
            if xcrun notarytool history --keychain-profile "$candidate" >/dev/null 2>&1; then
                profile="$candidate"
                break
            fi
        done
        [ -n "$profile" ] || { echo "No notarytool profile found (tried dumptruck-notary, backlot-notary)" >&2; return 1; }
    fi
    echo "== notarizing with profile $profile (usually a few minutes)"
    result="$(xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json)" \
        || { echo "notarytool submit failed; check the '$profile' keychain profile" >&2; return 1; }
    status="$(/usr/bin/plutil -extract status raw -o - - <<< "$result")"
    submission="$(/usr/bin/plutil -extract id raw -o - - <<< "$result")"
    if [ "$status" != "Accepted" ]; then
        echo "Notarization $status (submission $submission). Apple's log:" >&2
        xcrun notarytool log "$submission" --keychain-profile "$profile" >&2 || true
        return 1
    fi
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature -v "$dmg"
    printf 'Notarized and stapled (submission %s)\n' "$submission"
}

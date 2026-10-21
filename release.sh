#!/bin/bash
# Build, sign, notarize, staple, make a drag-to-Applications disk image, and publish.
# Usage: ./release.sh 1.1.1 [notes.txt]
# The Apple ID password stays in the Keychain profile. It is not read from this file.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-}"
NOTES_FILE="${2:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: ./release.sh <version> [notes-file]" >&2
    exit 1
fi

PROFILE="${NOTARY_KEYCHAIN_PROFILE:-doom2016-notary}"
SIGN_ID="${SIGN_ID:-Developer ID Application: Mehmet Akif Ozdas (2DG34W64L7)}"
if ! security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    echo "Developer ID certificate not found: $SIGN_ID" >&2
    exit 1
fi
if ! history_err="$(xcrun notarytool history --keychain-profile "$PROFILE" 2>&1 >/dev/null)"; then
    if grep -q "No Keychain password item" <<<"$history_err"; then
        cat >&2 <<EOF
No notarytool keychain profile named "$PROFILE".
Store the Apple ID credentials in the Keychain once. Do not put the password in the repo:

  xcrun notarytool store-credentials "$PROFILE" --apple-id YOU@icloud.com --team-id 2DG34W64L7

Use an app-specific password. Set NOTARY_KEYCHAIN_PROFILE if the profile has another name.
EOF
        exit 1
    fi
    echo "Could not read notarization history for profile $PROFILE:" >&2
    echo "$history_err" >&2
fi

submit_notary() {
    local file="$1"
    echo "Submitting $(basename "$file") for notarization…"
    local json
    json="$(mktemp)"
    set +e
    xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json >"$json"
    local status=$?
    set -e
    if ! python3 - "$json" "$PROFILE" "$status" <<'PY'
import json, subprocess, sys
path, profile, submit_status = sys.argv[1:]
raw = open(path, encoding="utf-8").read().strip()
report = None
if raw:
    try:
        report = json.loads(raw)
    except json.JSONDecodeError:
        print(raw)
if not isinstance(report, dict):
    print(f"notarytool submit failed (exit {submit_status}).")
    sys.exit(1)
status = report.get("status")
submission = report.get("id")
print(f"Notarization status: {status} ({submission})")
if status == "Accepted":
    sys.exit(0)
if raw:
    print(raw)
if submission:
    print("Fetching the notarization log…")
    subprocess.run(["xcrun", "notarytool", "log", submission, "--keychain-profile", profile], check=False)
sys.exit(1)
PY
    then
        rm -f "$json"
        exit 1
    fi
    rm -f "$json"
}

export VERSION BUILD="$VERSION" REQUIRE_SIGN=1 SIGN_ID
"$ROOT/build_app.sh"

APP="$ROOT/dist/NathanDrakeCollection.app"
NOTARY_ZIP="$ROOT/dist/NathanDrakeCollection-${VERSION}.notarize.zip"
FINAL_ZIP="$ROOT/dist/NathanDrakeCollection-macos.zip"
FINAL_DMG="$ROOT/dist/NathanDrakeCollection-macos.dmg"
rm -f "$NOTARY_ZIP" "$FINAL_ZIP" "$FINAL_DMG"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
submit_notary "$NOTARY_ZIP"
rm -f "$NOTARY_ZIP"

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
ditto -c -k --keepParent "$APP" "$FINAL_ZIP"

chmod +x "$ROOT/macos/make_dmg.sh"
"$ROOT/macos/make_dmg.sh" "$APP" "$ROOT/README-macOS.txt" "$FINAL_DMG"
submit_notary "$FINAL_DMG"
xcrun stapler staple "$FINAL_DMG"
xcrun stapler validate "$FINAL_DMG"

if [[ -n "$NOTES_FILE" ]]; then
    gh release create "v$VERSION" "$FINAL_DMG" "$FINAL_ZIP" \
        --repo truwa/nathan-drake-collection-macos \
        --title "Nathan Drake Collection $VERSION" \
        --notes-file "$NOTES_FILE"
else
    gh release create "v$VERSION" "$FINAL_DMG" "$FINAL_ZIP" \
        --repo truwa/nathan-drake-collection-macos \
        --title "Nathan Drake Collection $VERSION" \
        --notes "$(cat <<EOF
Download NathanDrakeCollection-macos.dmg, open it, and drag NathanDrakeCollection.app onto Applications.

This release is signed with Developer ID and notarized by Apple. A double-click opens it.

The games are not included. You need your own decrypted PS4 dump. The BilalReloaded engine is already inside the app.
EOF
)"
fi
echo "Published $FINAL_DMG as release v$VERSION"

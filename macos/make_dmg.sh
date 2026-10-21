#!/bin/bash
# Build a drag-to-Applications disk image: the app, /Applications, and README.txt.
# Usage: make_dmg.sh <App.app> <README.txt> <output.dmg>
set -euo pipefail
APP="${1:?}"
README="${2:?}"
OUTPUT="${3:?}"
[[ -d "$APP" ]] || { echo "Missing app: $APP" >&2; exit 1; }
[[ -f "$README" ]] || { echo "Missing README: $README" >&2; exit 1; }

VOL="Nathan Drake Collection"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ndc-dmg.XXXXXX")"
cleanup() {
    if [[ -n "${DEVICE:-}" ]]; then
        hdiutil detach "$DEVICE" -quiet || true
    fi
    rm -rf "$STAGE" "${OUTPUT%.dmg}.rw.dmg"
}
trap cleanup EXIT

ditto "$APP" "$STAGE/NathanDrakeCollection.app"
ln -s /Applications "$STAGE/Applications"
cp "$README" "$STAGE/README.txt"

RW="${OUTPUT%.dmg}.rw.dmg"
rm -f "$RW" "$OUTPUT"
hdiutil create -quiet -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/^\/dev\// { dev=$1 } END { print dev }')"
MOUNT="/Volumes/$VOL"
for _ in $(seq 1 25); do
    [[ -d "$MOUNT/NathanDrakeCollection.app" ]] && break
    sleep 0.2
done

osascript <<EOF || true
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {280, 140, 920, 560}
        set theView to icon view options of container window
        set arrangement of theView to not arranged
        set icon size of theView to 128
        set position of item "NathanDrakeCollection.app" of container window to {160, 180}
        set position of item "Applications" of container window to {480, 180}
        set position of item "README.txt" of container window to {320, 360}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

sync
hdiutil detach "$DEVICE" -quiet
DEVICE=""
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT"
rm -f "$RW"
echo "Built $OUTPUT"
du -sh "$OUTPUT"

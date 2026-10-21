#!/bin/bash
# Assemble dist/NathanDrakeCollection.app for the BilalReloaded native Mac runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/NathanDrakeCollection.app"
NATIVE_SRC="${NATIVE_SRC:-$(cd "$ROOT/../uncharted-bilal-work/bilal" && pwd)}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
    "$APP/Contents/Resources/engine" \
    "$APP/Contents/Resources/covers"

cp "$ROOT/macos/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/macos/covers/u1.jpg" "$ROOT/macos/covers/u2.jpg" "$ROOT/macos/covers/u3.jpg" \
    "$APP/Contents/Resources/covers/"
cp "$ROOT/launch.py" "$ROOT/NOTICES.txt" "$APP/Contents/Resources/engine/"
cp "$ROOT/NOTICES.txt" "$ROOT/README-macOS.txt" "$APP/Contents/Resources/"

if [[ -x "$NATIVE_SRC/gow3_pc/out/gow3-probe" && -f "$NATIVE_SRC/tools/probe_uncharted.py" ]]; then
    mkdir -p "$APP/Contents/Resources/native/gow3_pc/out" "$APP/Contents/Resources/native/tools"
    # Local builds keep the probe in the Bilal checkout so rpaths and KosmicKrisp
    # stay valid. The app records that path for Play.
    printf '%s\n' "$NATIVE_SRC" > "$APP/Contents/Resources/native-root.txt"
fi

PYTHON_DIR="$ROOT/dist/python-standalone"
if [[ ! -x "$PYTHON_DIR/bin/python3" ]]; then
    mkdir -p "$ROOT/dist"
    ASSET="$(curl -fsSL "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest" \
        | python3 -c 'import json,sys; rel=json.load(sys.stdin); print(next(a["browser_download_url"] for a in rel["assets"] if "aarch64-apple-darwin" in a["name"] and a["name"].endswith("install_only.tar.gz")))')"
    curl -fL "$ASSET" -o "$ROOT/dist/python.tar.gz"
    rm -rf "$PYTHON_DIR"
    mkdir -p "$PYTHON_DIR"
    tar -xzf "$ROOT/dist/python.tar.gz" -C "$PYTHON_DIR" --strip-components 1
    rm "$ROOT/dist/python.tar.gz"
fi
mkdir -p "$APP/Contents/Resources/python"
rsync -a "$PYTHON_DIR/" "$APP/Contents/Resources/python/"

swiftc -parse-as-library -O -o "$APP/Contents/MacOS/NathanDrakeCollection" \
    -framework SwiftUI -framework AppKit \
    "$ROOT/macos/NathanDrakeCollectionApp.swift" \
    "$ROOT/macos/AppUpdate.swift"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>NathanDrakeCollection</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.macgametest.nathandrakecollection</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDisplayName</key>
    <string>Nathan Drake Collection</string>
    <key>CFBundleName</key>
    <string>NathanDrakeCollection</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSDesktopFolderUsageDescription</key>
    <string>The game folder may be on the Desktop.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>The game folder may be in Documents.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>The game folder may be in Downloads.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>The game folder may be on an external volume.</string>
</dict>
</plist>
EOF

IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Mehmet Akif Ozdas (2DG34W64L7)}"
if security find-identity -v -p codesigning | grep -F "$IDENTITY" >/dev/null; then
    codesign --force --deep --options runtime \
        --entitlements "$ROOT/macos/entitlements.plist" \
        --sign "$IDENTITY" \
        "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    echo "Signed with $IDENTITY"
else
    echo "No Developer ID identity named '$IDENTITY'; app is unsigned." >&2
fi

echo "Built $APP"
du -sh "$APP"

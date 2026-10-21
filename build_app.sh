#!/bin/bash
# Assemble dist/NathanDrakeCollection.app for the BilalReloaded native Mac runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/NathanDrakeCollection.app"
NATIVE_SRC="${NATIVE_SRC:-$(cd "$ROOT/../uncharted-bilal-work/bilal" && pwd)}"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$VERSION}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
    "$APP/Contents/Resources/engine" \
    "$APP/Contents/Resources/covers"

cp "$ROOT/macos/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/macos/covers/u1.jpg" "$ROOT/macos/covers/u2.jpg" "$ROOT/macos/covers/u3.jpg" \
    "$APP/Contents/Resources/covers/"
cp "$ROOT/launch.py" "$ROOT/NOTICES.txt" "$APP/Contents/Resources/engine/"
cp "$ROOT/NOTICES.txt" "$ROOT/README-macOS.txt" "$APP/Contents/Resources/"

NATIVE_OUT="$APP/Contents/Resources/native/gow3_pc/out"
DEPS="${SPARTAN_MACOS_DEPS:-$HOME/Library/Caches/spartanport-macos-deps}"
if [[ ! -x "$NATIVE_SRC/gow3_pc/out/gow3-probe" || ! -f "$NATIVE_SRC/tools/probe_uncharted.py" ]]; then
    echo "Native probe missing at $NATIVE_SRC (build gow3-probe first)." >&2
    exit 1
fi
if [[ ! -f "$DEPS/lib/libvulkan_kosmickrisp.dylib" ]]; then
    echo "KosmicKrisp missing at $DEPS. Build SpartanPort macOS deps first." >&2
    exit 1
fi
mkdir -p "$NATIVE_OUT/gpu" "$NATIVE_OUT/vulkan" \
    "$APP/Contents/Resources/native/gow3_pc/scripts" \
    "$APP/Contents/Resources/native/tools"
strip -S -o "$NATIVE_OUT/gow3-probe" "$NATIVE_SRC/gow3_pc/out/gow3-probe"
chmod +x "$NATIVE_OUT/gow3-probe"
strip -S -o "$NATIVE_OUT/gpu/libgow3gpu.dylib" "$NATIVE_SRC/gow3_pc/out/gpu/libgow3gpu.dylib"
cp "$DEPS/lib/libvulkan_kosmickrisp.dylib" "$NATIVE_OUT/vulkan/"
cp "$NATIVE_SRC/tools/probe_uncharted.py" "$APP/Contents/Resources/native/tools/"
cp "$NATIVE_SRC/gow3_pc/scripts/"*.py "$APP/Contents/Resources/native/gow3_pc/scripts/"
printf 'bundled\n' > "$APP/Contents/Resources/native/VERSION"
printf '%s\n' "$VERSION" > "$APP/Contents/Resources/native/.bundle-stamp"
python3 "$ROOT/macos/bundle_native.py" "$NATIVE_OUT" "$DEPS"
# Menu bar uses the launched executable name (Windows already copies this to Uncharted.exe).
ln -f "$NATIVE_OUT/gow3-probe" "$NATIVE_OUT/Uncharted"

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

cat > "$APP/Contents/Info.plist" <<EOF
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
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
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

SIGN_ID="${SIGN_ID:-${CODESIGN_IDENTITY:-Developer ID Application: Mehmet Akif Ozdas (2DG34W64L7)}}"
ENTITLEMENTS="$ROOT/macos/entitlements.plist"
if ! security find-identity -v -p codesigning | grep -F "$SIGN_ID" >/dev/null; then
    if [[ "${REQUIRE_SIGN:-}" == "1" ]]; then
        echo "Developer ID certificate not found: $SIGN_ID" >&2
        exit 1
    fi
    echo "Built $APP (unsigned; certificate not found)"
    du -sh "$APP"
    exit 0
fi
python3 - "$APP" "$SIGN_ID" "$ENTITLEMENTS" <<'PY'
import os, subprocess, sys
root, identity, entitlements = sys.argv[1:]
main = os.path.join(root, "Contents/MacOS/NathanDrakeCollection")
found = []
for dirpath, _, names in os.walk(root):
    for name in names:
        path = os.path.join(dirpath, name)
        if os.path.islink(path) or os.path.realpath(path) == os.path.realpath(main):
            continue
        kind = subprocess.run(["file", "-b", path], capture_output=True, text=True).stdout
        if "Mach-O" in kind:
            found.append((path.count(os.sep), path, kind))
found.sort(reverse=True)
for _, path, kind in found:
    command = [
        "codesign", "--force", "--sign", identity,
        "--options", "runtime", "--timestamp",
    ]
    if "executable" in kind and "shared library" not in kind and "bundle" not in kind:
        command.extend(["--entitlements", entitlements])
    command.append(path)
    subprocess.check_call(command)
subprocess.check_call([
    "codesign", "--force", "--sign", identity,
    "--options", "runtime", "--timestamp",
    "--entitlements", entitlements, root,
])
PY
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Signed with $SIGN_ID"

echo "Built $APP"
du -sh "$APP"

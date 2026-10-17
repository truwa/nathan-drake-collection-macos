#!/bin/bash
# Assemble dist/Uncharted.app from the Wine engine, KosmicKrisp, and the port runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/Uncharted.app"
KOSMIC_SRC="${KOSMIC_SRC:-$ROOT/dist/upstream/kosmickrisp-x86_64}"
PORT_SRC="${PORT_SRC:-/Volumes/S990PRO/uncharted-windows}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
    "$APP/Contents/Resources/engine" \
    "$APP/Contents/Resources/vulkan/icd.d" \
    "$APP/Contents/Resources/port/licenses" \
    "$APP/Contents/Frameworks"

cp "$KOSMIC_SRC/libvulkan_kosmickrisp.dylib" "$APP/Contents/Frameworks/"
cp "$KOSMIC_SRC/kosmickrisp_icd.json" "$APP/Contents/Resources/vulkan/icd.d/"

rsync -a \
    --exclude 'bbport_dlss.dll' \
    --exclude 'nvngx_dlss.dll' \
    --exclude 'nvngx_dlssg.dll' \
    --exclude 'bb-probe-macos.exe' \
    --exclude 'bb-probe-macos.exe.*' \
    "$PORT_SRC/bin/" "$APP/Contents/Resources/port/bin/"
rsync -a "$PORT_SRC/scripts/" "$APP/Contents/Resources/port/scripts/"
if [[ -d "$PORT_SRC/fsr4_shaders" ]]; then
    rsync -a "$PORT_SRC/fsr4_shaders/" "$APP/Contents/Resources/port/fsr4_shaders/"
fi
cp "$PORT_SRC/LICENSE" "$PORT_SRC/README.txt" "$PORT_SRC/bbport.ini" "$PORT_SRC/input.ini" \
    "$APP/Contents/Resources/port/"
rsync -a --exclude 'NVIDIA-DLSS-LICENSE.txt' "$PORT_SRC/licenses/" "$APP/Contents/Resources/port/licenses/"
printf '%s\n' "${PORT_VERSION:-0.3.3}" > "$APP/Contents/Resources/port/PORT_VERSION"
mkdir -p "$APP/Contents/Resources/covers"
if [[ -d "$PORT_SRC/_internal/covers" ]]; then
    cp "$PORT_SRC/_internal/covers/u1.jpg" "$PORT_SRC/_internal/covers/u2.jpg" \
        "$PORT_SRC/_internal/covers/u3.jpg" "$APP/Contents/Resources/covers/"
fi

cp "$ROOT/launch.py" "$ROOT/patch_probe.py" "$ROOT/tls_adapter.c" \
    "$ROOT/uncharted-crossover-tls.dll" "$ROOT/NOTICES.txt" \
    "$APP/Contents/Resources/engine/"
cp "$ROOT/NOTICES.txt" "$APP/Contents/Resources/NOTICES.txt"

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

swiftc -parse-as-library -O -o "$APP/Contents/MacOS/Uncharted" \
    -framework SwiftUI -framework AppKit \
    "$ROOT/macos/UnchartedApp.swift"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Uncharted</string>
    <key>CFBundleIdentifier</key>
    <string>com.uncharted.macos</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDisplayName</key>
    <string>Nathan Drake Collection</string>
    <key>CFBundleName</key>
    <string>Nathan Drake Collection</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.6</string>
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

echo "Built $APP"
du -sh "$APP"

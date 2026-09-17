#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/custom/dist/YuE Studio.app"
if [[ -n "${JUCE_ROOT:-}" ]]; then
  cmake -S "$ROOT/mastering" -B "$ROOT/mastering/build" -G Ninja -DCMAKE_BUILD_TYPE=Release "-DJUCE_ROOT=$JUCE_ROOT"
else
  cmake -S "$ROOT/mastering" -B "$ROOT/mastering/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
fi
cmake --build "$ROOT/mastering/build" -j 6
"$ROOT/mastering/build/StudioMasterEngine_artefacts/Release/StudioMasterEngine" --catalog > "$ROOT/custom/Assets/StudioMasteringCatalog.json.tmp"
mv "$ROOT/custom/Assets/StudioMasteringCatalog.json.tmp" "$ROOT/custom/Assets/StudioMasteringCatalog.json"
swift build -c release --package-path "$ROOT/app/YuEStudio"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/worker" "$APP/Contents/Helpers" "$ROOT/custom/Assets/AppIcon.iconset"
# Remove obsolete names only from this generated bundle.
rm -f "$APP/Contents/Helpers/ReSoulMaster" "$APP/Contents/Resources/ReSoulCatalog.json"
cp "$ROOT/app/YuEStudio/.build/release/YuEStudio" "$APP/Contents/MacOS/YuE Studio"
cp "$ROOT/mastering/build/StudioMasterEngine_artefacts/Release/StudioMasterEngine" "$APP/Contents/Helpers/StudioMasterEngine"
cp "$ROOT/custom/Assets/StudioMasteringCatalog.json" "$ROOT/mastering/JUCE-LICENSE.md" "$ROOT/mastering/NOTICE.md" "$ROOT/mastering/LICENSE" "$APP/Contents/Resources/"
codesign --force --sign - "$APP/Contents/Helpers/StudioMasterEngine"
cp "$ROOT/tools/yue2_worker.py" "$ROOT/tools/studio_support.py" "$APP/Contents/Resources/worker/"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ROOT/custom/Assets/AppIcon.png" --out "$ROOT/custom/Assets/AppIcon.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$ROOT/custom/Assets/AppIcon.png" --out "$ROOT/custom/Assets/AppIcon.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ROOT/custom/Assets/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/custom/Assets/AppIcon.png" "$APP/Contents/Resources/AppIcon.png"
cp "$ROOT/mastering/LICENSE" "$APP/Contents/Resources/MASTERING-LICENSE"
cp "$ROOT/LICENSE" "$ROOT/MODEL_LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>YuE Studio</string>
<key>CFBundleDisplayName</key><string>YuE Studio</string>
<key>CFBundleIdentifier</key><string>com.solution7.yuestudio.custom</string>
<key>CFBundleExecutable</key><string>YuE Studio</string>
<key>CFBundleVersion</key><string>20260916.10</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Custom edition. Based on YuE Studio by Tony Weston and YuE2 by M·A·P. Apache-2.0 studio; AGPL-3.0 mastering; model license applies.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"

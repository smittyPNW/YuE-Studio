#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/custom/dist/YuE Studio.app"
swift build -c release --package-path "$ROOT/app/YuEStudio"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/worker" "$APP/Contents/Helpers" "$ROOT/custom/Assets/AppIcon.iconset"
cp "$ROOT/app/YuEStudio/.build/release/YuEStudio" "$APP/Contents/MacOS/YuE Studio"
# Optional private engine. This directory must come from an authorized provider.
if [[ -n "${RESOUL_ENGINE_DIR:-}" ]]; then
  test -x "$RESOUL_ENGINE_DIR/ReSoulMaster"
  test -f "$RESOUL_ENGINE_DIR/ReSoulCatalog.json"
  test -d "$RESOUL_ENGINE_DIR/licenses"
  cp "$RESOUL_ENGINE_DIR/ReSoulMaster" "$APP/Contents/Helpers/"
  cp "$RESOUL_ENGINE_DIR/ReSoulCatalog.json" "$APP/Contents/Resources/"
  cp -R "$RESOUL_ENGINE_DIR/licenses" "$APP/Contents/Resources/ReSoul-Licenses"
  codesign --force --sign - "$APP/Contents/Helpers/ReSoulMaster"
else
  # Fail if an old private bundle occupies this output; never publish it by mistake.
  test ! -f "$APP/Contents/Helpers/ReSoulMaster" || { echo "Use a clean public build directory." >&2; exit 1; }
fi
cp "$ROOT/tools/yue2_worker.py" "$ROOT/tools/studio_support.py" "$APP/Contents/Resources/worker/"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ROOT/custom/Assets/AppIcon.png" --out "$ROOT/custom/Assets/AppIcon.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$ROOT/custom/Assets/AppIcon.png" --out "$ROOT/custom/Assets/AppIcon.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ROOT/custom/Assets/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/custom/Assets/AppIcon.png" "$APP/Contents/Resources/AppIcon.png"
cp "$ROOT/LICENSE" "$ROOT/MODEL_LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>YuE Studio</string>
<key>CFBundleDisplayName</key><string>YuE Studio</string>
<key>CFBundleIdentifier</key><string>com.solution7.yuestudio.custom</string>
<key>CFBundleExecutable</key><string>YuE Studio</string>
<key>CFBundleVersion</key><string>20260916.8</string>
<key>CFBundleShortVersionString</key><string>0.3.1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Custom edition. Based on YuE Studio by Tony Weston and YuE2 by M·A·P. Apache-2.0 public code; model and optional engine licenses apply.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"

#!/bin/bash
# Build the app first with custom/package-local.sh. Credentials stay outside source.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${SOURCE_APP:-$ROOT/custom/dist/YuE Studio.app}"
DIST="${DISTRIBUTION_DIR:-$ROOT/custom/dist}"
SIGN="${SIGN_IDENTITY:--}"
NOTARIZE="${NOTARIZE:-0}"
command -v uv >/dev/null || { echo "Install uv to run the pinned dmgbuild tool." >&2; exit 1; }
[[ -d "$SOURCE_APP" ]] || { echo "Build the app first, or set SOURCE_APP." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")
mkdir -p "$DIST"
DMG="$DIST/YuE-Studio-$VERSION-Apple-Silicon.dmg"
[[ ! -e "$DMG" ]] || { echo "Refusing to overwrite $DMG; choose a new DISTRIBUTION_DIR." >&2; exit 1; }
if [[ "$NOTARIZE" == 1 ]]; then
  [[ "$SIGN" != - ]] || { echo "Notarization requires SIGN_IDENTITY (Developer ID Application)." >&2; exit 1; }
  if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    : "${NOTARY_KEY_PATH:?Set NOTARY_PROFILE or NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER}"
    : "${NOTARY_KEY_ID:?Missing NOTARY_KEY_ID}"
    : "${NOTARY_ISSUER:?Missing NOTARY_ISSUER}"
  fi
fi
STAGE=$(mktemp -d "$DIST/dmg-stage.XXXXXX")
MOUNT=""
cleanup() {
  if [[ -n "$MOUNT" ]]; then
    hdiutil detach "$MOUNT" >/dev/null || { echo "Could not eject verification volume; preserving $STAGE" >&2; return; }
  fi
  rm -rf "$STAGE"
}
trap cleanup EXIT
APP="$STAGE/YuE Studio.app"
ditto "$SOURCE_APP" "$APP"
cp "$ROOT/custom/Getting Started.html" "$STAGE/Getting Started.html"
swift "$ROOT/custom/dmg-background.swift" "$STAGE/background.png"

if [[ "$SIGN" == - ]]; then
  for HELPER in "$APP/Contents/Helpers/"*; do codesign --force --sign - "$HELPER"; done
  codesign --force --sign - "$APP"
else
  for HELPER in "$APP/Contents/Helpers/"*; do codesign --force --options runtime --timestamp --sign "$SIGN" "$HELPER"; done
  codesign --force --options runtime --timestamp --sign "$SIGN" "$APP"
fi
codesign --verify --deep --strict "$APP"

notarize() {
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  fi
}
if [[ "$NOTARIZE" == 1 ]]; then
  ditto -c -k --keepParent "$APP" "$STAGE/app.zip"
  notarize "$STAGE/app.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

uv tool run --from dmgbuild==1.6.7 dmgbuild -s "$ROOT/custom/dmg-settings.py" -D "stage=$STAGE" "YuE Studio" "$DMG"
# Validate the final copy too: Finder metadata changes can invalidate a signed app.
mkdir "$STAGE/verification"
hdiutil attach -readonly -nobrowse -mountpoint "$STAGE/verification" "$DMG" >/dev/null
MOUNT="$STAGE/verification"
codesign --verify --deep --strict "$MOUNT/YuE Studio.app"
[[ "$(readlink "$MOUNT/Applications")" == /Applications ]]
"$MOUNT/YuE Studio.app/Contents/Helpers/StudioMasterEngine" --catalog >/dev/null
if [[ "$NOTARIZE" == 1 ]]; then
  xcrun stapler validate "$MOUNT/YuE Studio.app"
fi
hdiutil detach "$MOUNT" >/dev/null
MOUNT=""
if [[ "$SIGN" != - ]]; then
  codesign --force --timestamp --sign "$SIGN" "$DMG"
fi
hdiutil verify "$DMG"
if [[ "$NOTARIZE" == 1 ]]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
printf 'Disk image: %s\n' "$DMG"

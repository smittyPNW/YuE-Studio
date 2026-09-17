#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/custom/build/mp3"
ARCHIVE="$BUILD/lame-4.0.tar.gz"
SHA="3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb"
mkdir -p "$BUILD"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 3 'https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz' -o "$ARCHIVE.partial"
  mv "$ARCHIVE.partial" "$ARCHIVE"
fi
echo "$SHA  $ARCHIVE" | shasum -a 256 -c -
if [[ ! -x "$BUILD/lame-4.0/frontend/lame" || ! -f "$BUILD/.built-macos14-lame4.0-v1" ]]; then
  command -v pkg-config >/dev/null || { echo 'Install the build dependency: brew install pkgconf' >&2; exit 1; }
  tar -xzf "$ARCHIVE" -C "$BUILD"
  cd "$BUILD/lame-4.0"
  if [[ -f Makefile ]]; then make clean; fi
  export MACOSX_DEPLOYMENT_TARGET=14.0
  ./configure --disable-decoder --disable-shared --enable-static --disable-nasm ac_cv_prog_cc_c23=no CFLAGS='-O2 -Wno-implicit-function-declaration -include locale.h'
  make -j 4
  touch "$BUILD/.built-macos14-lame4.0-v1"
fi
# Do not accidentally ship a helper linked to development-machine libraries.
if otool -L "$BUILD/lame-4.0/frontend/lame" | tail -n +2 | grep -Ev '^[[:space:]]*(/usr/lib/|/System/Library/)' | grep -q .; then
  echo 'MP3 helper has a non-system dependency; packaging stopped.' >&2
  exit 1
fi

#!/usr/bin/env bash
# build.sh – Build PVTagPlugin.dylib, inject it into PictureView, and optionally package a DMG.
#
# Usage:
#   ./build.sh          – build patched app into ./build/PictureView.app
#   ./build.sh dmg      – also create ./dist/PictureView_tagged.dmg
#   ./build.sh install  – also copy to /Applications (replaces the existing app)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="/Applications/PictureView.app"
BUILD_DIR="$SCRIPT_DIR/build"
DIST_DIR="$SCRIPT_DIR/dist"
APP_DST="$BUILD_DIR/PictureView.app"
FRAMEWORKS="$APP_DST/Contents/Frameworks"
BINARY="$APP_DST/Contents/MacOS/PictureView"
DYLIB_NAME="PVTagPlugin.dylib"
DYLIB_DST="$FRAMEWORKS/$DYLIB_NAME"
DYLIB_INSTALL_PATH="@executable_path/../Frameworks/$DYLIB_NAME"

echo "==> Copying app from $APP_SRC"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "==> Compiling $DYLIB_NAME (universal)"
clang \
    -fobjc-arc \
    -framework Foundation \
    -framework AppKit \
    -dynamiclib \
    -arch x86_64 -arch arm64 \
    -mmacosx-version-min=10.15 \
    -install_name "$DYLIB_INSTALL_PATH" \
    -o "$DYLIB_DST" \
    "$SCRIPT_DIR/src/PVTagPlugin.m"

echo "==> Injecting LC_LOAD_WEAK_DYLIB into binary"
python3 "$SCRIPT_DIR/tools/inject_macho.py" "$BINARY" "$DYLIB_INSTALL_PATH"

echo "==> Re-signing ad-hoc"
# Remove the original (team-signed) signature first, then ad-hoc sign.
codesign --remove-signature "$APP_DST" 2>/dev/null || true
codesign -f -s - --deep "$APP_DST"

echo "==> Clearing quarantine attribute"
xattr -cr "$APP_DST"

echo ""
echo "Patched app: $APP_DST"

# ── Optional: package DMG ────────────────────────────────────────────────────
if [[ "${1:-}" == "dmg" || "${1:-}" == "install" ]]; then
    mkdir -p "$DIST_DIR"
    DMG_PATH="$DIST_DIR/PictureView_tagged.dmg"
    echo "==> Packaging DMG → $DMG_PATH"
    rm -f "$DMG_PATH"
    hdiutil create \
        -volname "PictureView" \
        -srcfolder "$APP_DST" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
    echo "DMG: $DMG_PATH"
fi

# ── Optional: install ─────────────────────────────────────────────────────────
if [[ "${1:-}" == "install" ]]; then
    echo "==> Installing to /Applications (requires permission)"
    rm -rf /Applications/PictureView.app
    cp -R "$APP_DST" /Applications/PictureView.app
    echo "Installed."
fi

#!/usr/bin/env bash
# Builds dist/Wisp.app and dist/Wisp.dmg (+ Wisp.dmg.sha256) from source.
#
#   scripts/build.sh                 ad-hoc signed build (what CI and releases use)
#   WISP_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build.sh
#                                    sign with your Developer ID (hardened runtime)
#
# Needs only the Xcode Command Line Tools:  xcode-select --install
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$ROOT/engine/wisp.sh"
DIST="$ROOT/dist"
WORK="$DIST/.work"
APP="$DIST/Wisp.app"
DMG="$DIST/Wisp.dmg"
MIN_OS="11.0"                       # first macOS that runs on Apple Silicon
BUNDLE_ID="io.github.karanzykx.wisp"
IDENTITY="${WISP_SIGN_IDENTITY:--}"  # "-" means ad-hoc

command -v swiftc >/dev/null || { echo "swiftc not found. Run: xcode-select --install" >&2; exit 1; }
VERSION="$(/bin/bash "$ENGINE" --version | awk '{print $2}')"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected engine version: '$VERSION'" >&2; exit 1; }

step() { printf '▸ %s\n' "$*"; }

step "Wisp $VERSION: running the engine's safety self-test"
/bin/bash "$ENGINE" --self-test >/dev/null || { echo "Self-test failed. Not building." >&2; exit 1; }

rm -rf "$DIST"; mkdir -p "$WORK" "$APP/Contents/MacOS" "$APP/Contents/Resources"

step "Compiling for Apple Silicon and Intel (macOS $MIN_OS+)"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos$MIN_OS" \
    "$ROOT"/app/Sources/*.swift -o "$WORK/Wisp-$arch"
done
lipo -create "$WORK/Wisp-arm64" "$WORK/Wisp-x86_64" -output "$APP/Contents/MacOS/Wisp"

step "Drawing the icon"
swiftc -O "$ROOT/scripts/make_icon.swift" -o "$WORK/make_icon"
"$WORK/make_icon" "$WORK/icon_1024.png"
ICONSET="$WORK/AppIcon.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$WORK/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s * 2))" "$((s * 2))" "$WORK/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

step "Assembling the bundle"
cp "$ENGINE" "$APP/Contents/Resources/wisp.sh"
chmod 755 "$APP/Contents/Resources/wisp.sh"
cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Wisp</string>
  <key>CFBundleDisplayName</key><string>Wisp</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Wisp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Wisp contributors. MIT License.</string>
</dict>
</plist>
PLIST

step "Signing ($([[ "$IDENTITY" == "-" ]] && echo "ad-hoc" || echo "$IDENTITY"))"
xattr -cr "$APP"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - --timestamp=none "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

step "Building the disk image"
STAGE="$WORK/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Wisp" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
if [[ "$IDENTITY" != "-" ]]; then codesign --force --timestamp --sign "$IDENTITY" "$DMG"; fi
hdiutil verify "$DMG" >/dev/null
(cd "$DIST" && shasum -a 256 Wisp.dmg >Wisp.dmg.sha256)
rm -rf "$WORK"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Wisp")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo "Binary is not universal: $ARCHS" >&2; exit 1; }

echo
echo "✓ $APP"
echo "✓ $DMG  ($(du -h "$DMG" | awk '{print $1}'))"
echo "  version       $VERSION"
echo "  architectures $ARCHS"
echo "  sha256        $(cut -d' ' -f1 "$DIST/Wisp.dmg.sha256")"

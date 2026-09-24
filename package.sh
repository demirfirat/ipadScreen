#!/bin/bash
#
# Builds iPadScreen.app: a universal (Intel + Apple Silicon) macOS app that
# runs by double-clicking, with no Swift, Xcode or terminal required.
#
# Usage: ./package.sh
set -e

cd "$(dirname "$0")"

VERSION="1.0.0"
APP="build/iPadScreen.app"
ARM=".build/arm64-apple-macosx/release/ipadscreen"
X86=".build/x86_64-apple-macosx/release/ipadscreen"

echo ""
echo "  Packaging iPadScreen.app $VERSION…"
echo ""

# --- Build -----------------------------------------------------------------
echo "  → building arm64…"
swift build -c release --triple arm64-apple-macosx14.0 >/dev/null

echo "  → building x86_64…"
swift build -c release --triple x86_64-apple-macosx14.0 >/dev/null

# --- Bundle ----------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The web viewer (Safari fallback) and the app icon.
cp -R Sources/ipadscreen/web "$APP/Contents/Resources/"
cp assets/AppIcon.icns "$APP/Contents/Resources/"

echo "  → creating universal binary"
if [ -f "$X86" ]; then
    lipo -create "$ARM" "$X86" -output "$APP/Contents/MacOS/iPadScreen"
else
    cp "$ARM" "$APP/Contents/MacOS/iPadScreen"
fi
chmod +x "$APP/Contents/MacOS/iPadScreen"

# --- Info.plist ------------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>iPadScreen</string>
    <key>CFBundleDisplayName</key>
    <string>iPadScreen</string>
    <key>CFBundleIdentifier</key>
    <string>com.george.ipadscreen</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>iPadScreen</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# --- Sign ------------------------------------------------------------------
# With an ad-hoc signature macOS ties the Screen Recording permission to the
# binary's hash, which changes on every build, so the permission resets each
# time. A local certificate gives the app a stable identity and the
# permission survives rebuilds. Create one with ./setup-signing.sh.
IDENTITY="iPadScreen Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null \
        && echo "  → signed ($IDENTITY)" \
        || { echo "  ✗ signing with '$IDENTITY' failed"; exit 1; }
else
    codesign --force --deep --sign - "$APP" 2>/dev/null && echo "  → signed (ad-hoc)"
    echo "    Note: Screen Recording permission will reset on every build."
    echo "          Run ./setup-signing.sh once to make it stick."
fi

# --- Done ------------------------------------------------------------------
SIZE=$(du -sh "$APP" | cut -f1)
echo ""
echo "  ✓ Done: $PWD/$APP  ($SIZE)"
echo ""
echo "  To install on another Mac:"
echo "    1. Copy iPadScreen.app to /Applications"
echo "    2. On first launch: right-click › Open (Gatekeeper warning)"
echo "    3. Install BetterDisplay for the virtual display"
echo ""

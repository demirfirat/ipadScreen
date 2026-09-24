#!/bin/bash
#
# Builds the files for a GitHub release into build/release/:
#   iPadScreen-<version>-macOS.zip       the Mac app, signed ad-hoc
#   iPadScreen-<version>-iOS.deb         the iPad app (needs theos + SDK)
#   SHA256SUMS.txt
#
# Usage: ./release.sh
set -e

cd "$(dirname "$0")"

VERSION="$(sed -n 's/^VERSION="\(.*\)"/\1/p' package.sh)"
OUT="build/release"
rm -rf "$OUT"
mkdir -p "$OUT"

# --- Mac app ---------------------------------------------------------------
./package.sh --adhoc
# ditto keeps the bundle's symlinks and extended attributes intact, unlike zip.
ditto -c -k --keepParent build/iPadScreen.app "$OUT/iPadScreen-$VERSION-macOS.zip"

# --- iPad app --------------------------------------------------------------
if [ -z "$THEOS" ]; then
    echo "  ✗ THEOS isn't set; skipping the iPad app (see README › iPad app)"
else
    echo "  → building the iPad app…"
    (cd ios && make clean >/dev/null && make package FINALPACKAGE=1 >/dev/null)
    DEB="$(ls -t ios/packages/*_iphoneos-arm.deb | grep -v debug | head -1)"
    cp "$DEB" "$OUT/iPadScreen-$VERSION-iOS.deb"
fi

(cd "$OUT" && shasum -a 256 * > SHA256SUMS.txt)

echo ""
echo "  ✓ Release files in $PWD/$OUT:"
ls -lh "$OUT" | tail -n +2 | awk '{print "    " $5 "  " $9}'
echo ""

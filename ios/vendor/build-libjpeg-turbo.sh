#!/bin/bash
#
# Rebuilds the prebuilt libjpeg-turbo in this folder (armv7, NEON, iOS 6).
#
# The repository already ships the result, so you only need this to update
# libjpeg-turbo or to verify the binary yourself.
#
# Requirements: cmake (brew install cmake) and the iPhoneOS6.1 SDK at
# $THEOS/sdks/iPhoneOS6.1.sdk.
#
# Usage: ./build-libjpeg-turbo.sh
set -e

cd "$(dirname "$0")"

VERSION="3.0.4"
THEOS="${THEOS:-$HOME/theos}"
SDK="$THEOS/sdks/iPhoneOS6.1.sdk"
DEST="${DEST:-$PWD/libjpeg-turbo}"

if [ ! -d "$SDK" ]; then
    echo "  ✗ SDK not found: $SDK"
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "  → downloading libjpeg-turbo $VERSION…"
curl -sL -o src.tar.gz \
    "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$VERSION/libjpeg-turbo-$VERSION.tar.gz"
tar xzf src.tar.gz
cd "libjpeg-turbo-$VERSION"

echo "  → configuring (armv7, NEON)…"
mkdir build && cd build
cmake -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=Darwin \
    -DCMAKE_SYSTEM_PROCESSOR=arm \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_OSX_ARCHITECTURES=armv7 \
    -DCMAKE_C_FLAGS="-arch armv7 -miphoneos-version-min=6.0 -mfpu=neon -O3" \
    -DENABLE_SHARED=0 -DENABLE_STATIC=1 \
    -DWITH_SIMD=1 -DWITH_TURBOJPEG=0 \
    -DCMAKE_BUILD_TYPE=Release \
    .. >/dev/null

echo "  → building…"
make -j8 jpeg-static >/dev/null 2>&1

# Check NEON actually made it in: iOS builds of libjpeg-turbo have
# historically disabled it silently.
NEON=$(nm libjpeg.a 2>/dev/null | grep -ci neon || true)
if [ "$NEON" -eq 0 ]; then
    echo "  ✗ no NEON symbols in libjpeg.a; SIMD was not enabled"
    exit 1
fi

mkdir -p "$DEST/lib" "$DEST/include"
cp libjpeg.a "$DEST/lib/"
cp jconfig.h "$DEST/include/"
cp ../jpeglib.h ../jmorecfg.h ../jerror.h "$DEST/include/"
cp ../LICENSE.md ../README.ijg "$DEST/"

echo ""
echo "  ✓ libjpeg-turbo $VERSION → $DEST ($NEON NEON symbols)"
echo ""

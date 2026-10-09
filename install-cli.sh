#!/bin/bash
#
# Builds the command-line binary and links it into ~/.local/bin so you can
# run `ipadscreen --headless` from a terminal. Not needed for the app;
# use package.sh for that.
#
# Usage: ./install-cli.sh
set -e

cd "$(dirname "$0")"

echo ""
echo "  Installing ipadscreen CLI…"
echo ""

# Where SwiftPM puts the product depends on the toolchain version, so ask it
# instead of hardcoding .build/release.
BIN="$(swift build -c release --show-bin-path)/ipadscreen"

if [ ! -f "$BIN" ] || [ "Sources" -nt "$BIN" ]; then
    echo "  → building (about a minute the first time)…"
    swift build -c release
else
    echo "  → already built, skipping"
fi

[ -f "$BIN" ] || { echo "  ✗ build finished but $BIN is missing"; exit 1; }

mkdir -p "$HOME/.local/bin"
ln -sf "$BIN" "$HOME/.local/bin/ipadscreen"
echo "  → linked: ~/.local/bin/ipadscreen"

if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    SHELL_RC="$HOME/.zshrc"
    if ! grep -q '.local/bin' "$SHELL_RC" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
        echo "  → added to PATH ($SHELL_RC)"
        echo ""
        echo "  Open a new terminal, or run: source $SHELL_RC"
    fi
fi

echo ""
echo "  ✓ Done."
echo ""
echo "  Usage:"
echo "    ipadscreen --list        list displays"
echo "    ipadscreen --headless    start mirroring without the UI"
echo ""

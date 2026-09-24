#!/bin/bash
#
# Creates a self-signed code signing certificate for this machine.
#
# Why: with an ad-hoc signature macOS ties the Screen Recording permission
# to the app's hash. The hash changes on every build, so the permission
# resets each time and duplicate entries pile up in System Settings. An app
# signed with a stable certificate keeps the same identity across builds,
# so the permission sticks.
#
# The certificate is only trusted on this machine; an app you hand to
# someone else will still trigger a Gatekeeper warning. Run this once per
# machine. package.sh uses the certificate if it finds it and falls back to
# ad-hoc signing otherwise.
#
# Usage: ./setup-signing.sh
set -e

NAME="iPadScreen Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo ""
    echo "  ✓ '$NAME' is already installed, nothing to do."
    echo ""
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ""
echo "  → generating certificate…"

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = $NAME

[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# macOS's bundled openssl (LibreSSL) writes PKCS#12 in a format the keychain
# can read by default. Homebrew's OpenSSL 3 uses newer algorithms that
# `security import` rejects.
OPENSSL=/usr/bin/openssl

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# Importing into the keychain requires a password on the .p12. It's
# throwaway: the file is deleted on exit.
P12_PASS="ipadscreen"
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/cert.p12" -passout "pass:$P12_PASS" 2>/dev/null

echo "  → importing into login keychain…"
# -T lets codesign use the key without prompting on every build.
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
    -T /usr/bin/codesign >/dev/null

echo "  → trusting it for code signing…"
echo "     (macOS will ask for your password once)"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo ""
echo "  ✓ Installed: $NAME"
echo ""
echo "  Now run ./package.sh. Because the signature changes, you'll need to"
echo "  grant Screen Recording permission one last time; later builds keep it."
echo ""

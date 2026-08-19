#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN="$ROOT/signing"
KEYCHAIN="$SIGN/snaplane.keychain-db"
P12="$SIGN/snaplane.p12"
CERT="$SIGN/snaplane.cer"
CN="Snaplane"
PASSWORD="snaplane-local-sign"

mkdir -p "$SIGN"

if [[ ! -f "$KEYCHAIN" ]]; then
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
fi
security set-keychain-settings -lut 21600 "$KEYCHAIN" >/dev/null
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"

if ! security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CN"; then
  TMP="$(mktemp -d)"
  cat > "$TMP/cert.cnf" <<'EOF'
[ req ]
default_bits       = 2048
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = Snaplane
O = Snaplane

[ v3 ]
basicConstraints    = critical,CA:FALSE
keyUsage            = critical,digitalSignature
extendedKeyUsage    = critical,codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf" -extensions v3 >/dev/null 2>&1
  cp "$TMP/cert.pem" "$CERT"
  openssl pkcs12 -export -legacy \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$P12" -passout pass:"$PASSWORD" \
    -name "$CN" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1
  security import "$P12" -k "$KEYCHAIN" -P "$PASSWORD" \
    -A -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
  security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
  rm -rf "$TMP"
fi

if ! security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CN"; then
  echo "Failed to create a valid Snaplane code-signing identity" >&2
  security find-identity "$KEYCHAIN" >&2 || true
  exit 1
fi

echo "$KEYCHAIN"

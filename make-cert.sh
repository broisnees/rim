#!/bin/zsh
# Creates a self-signed code-signing identity "Rim Dev" in the login keychain (one time).
set -euo pipefail
NAME="Rim Dev"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "'$NAME' already exists"; exit 0; fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -legacy -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:rim 2>/dev/null \
  || openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:rim
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P rim -T /usr/bin/codesign
echo "created '$NAME'"

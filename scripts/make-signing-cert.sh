#!/usr/bin/env bash
# Creates a local "Margin Dev" code signing certificate in a small keychain of
# its own (~/Library/Keychains/margin-signing.keychain-db).
#
# Why: macOS ties Screen Recording and Accessibility to an app's signature.
# With a stable certificate, Margin keeps its permissions across rebuilds.
# Why its own keychain: its password is known, so codesign can use the key
# without asking for your login password.
#
# Safe to run more than once. Prints the keychain path on success.
set -euo pipefail

NAME="Margin Dev"
KEYCHAIN="$HOME/Library/Keychains/margin-signing.keychain-db"
PASSWORD="margin-local-signing"

# A keychain made with another password (an older setup) can't be unlocked
# here, so every build fell back to an ad hoc signature and macOS forgot
# Margin's permissions. Set it aside, once, and start a fresh one.
if [[ -f "$KEYCHAIN" ]] && ! security unlock-keychain -p "$PASSWORD" "$KEYCHAIN" 2>/dev/null; then
  OLD="${KEYCHAIN%.keychain-db}-$(date +%Y%m%d-%H%M%S).old.keychain-db"
  # shellcheck disable=SC2046
  security list-keychains -d user -s $(security list-keychains -d user | tr -d '"' | grep -v "margin-signing")
  mv "$KEYCHAIN" "$OLD"
  echo "Margin's signing keychain had a different password. Set it aside ($OLD) and made a new one." >&2
fi

if [[ ! -f "$KEYCHAIN" ]]; then
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
fi
# Unlock first (with its own known password, so macOS never has to ask),
# then tell it never to lock on its own. The other way round, changing the
# settings of a locked keychain made macOS ask for its password.
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"

if ! security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/cert.cnf" <<CNF
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
CNF
  # The system openssl (LibreSSL) writes a .p12 the macOS keychain accepts.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/cert.p12" -passout pass:margin
  security import "$TMP/cert.p12" -k "$KEYCHAIN" -P margin -T /usr/bin/codesign >/dev/null
  # Let Apple's tools (codesign) use the key without a password dialog.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
  echo "Created certificate \"$NAME\"." >&2
fi

# codesign looks for identities in the keychain search list: add ours once.
if ! security list-keychains -d user | grep -q "margin-signing.keychain"; then
  # shellcheck disable=SC2046
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
fi

echo "$KEYCHAIN"

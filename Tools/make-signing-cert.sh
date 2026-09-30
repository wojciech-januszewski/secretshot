#!/bin/bash
# Creates a local self-signed code signing identity called "SecretShot Dev".
#
# Why: an ad-hoc signature gets a new cdhash on every build, and TCC keys the
# Screen Recording grant to that hash — so the permission prompt comes back after
# every rebuild. A stable identity gives the bundle a stable designated
# requirement, and the grant survives.
#
# This certificate is local-only. It does NOT let you distribute the app to
# anyone else — that still needs an Apple Developer ID.
#
# Undo:  security delete-certificate -c "SecretShot Dev" ~/Library/Keychains/login.keychain-db
#
# Note: deliberately NOT using `set -e`. Several steps are allowed to fail and
# fall back to another strategy, and an early exit would hide which one worked.
set -uo pipefail

NAME="SecretShot Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

has_identity() {
  security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"
}

if has_identity; then
  echo "==> Identity '$NAME' already exists. Nothing to do."
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

echo "==> Generating a 10-year self-signed code signing certificate…"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/ss.key" -out "$WORK/ss.crt" \
  -subj "/CN=$NAME/O=SecretShot/C=PL" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

if [[ ! -s "$WORK/ss.crt" || ! -s "$WORK/ss.key" ]]; then
  echo "!!  Certificate generation failed. Is openssl present?" >&2
  exit 1
fi

echo "==> Importing into your login keychain."
echo "    macOS may ask for your login password — that is the keychain unlocking."

imported=0

# Strategy 1: import the PEM key and certificate separately.
# Avoids PKCS#12 entirely, which is where macOS is fussiest.
if security import "$WORK/ss.key" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null 2>&1 &&
   security import "$WORK/ss.crt" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null 2>&1; then
  echo "    Imported as separate PEM key + certificate."
  imported=1
fi

# Strategy 2: PKCS#12, but with the algorithms macOS actually accepts.
# LibreSSL defaults to pbeWithSHA1And40BitRC2-CBC, which modern macOS rejects
# while reporting the misleading "MAC verification failed (wrong password?)".
if [[ $imported -eq 0 ]]; then
  echo "    PEM import did not take; retrying via PKCS#12 (3DES, SHA-1 MAC)…"
  openssl pkcs12 -export -out "$WORK/ss.p12" \
    -inkey "$WORK/ss.key" -in "$WORK/ss.crt" -name "$NAME" \
    -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
    -passout pass:secretshot 2>/dev/null

  if security import "$WORK/ss.p12" -k "$KEYCHAIN" -P secretshot -T /usr/bin/codesign; then
    echo "    Imported from PKCS#12."
    imported=1
  fi
fi

if [[ $imported -eq 0 ]]; then
  echo
  echo "!!  Could not import the identity automatically."
  echo "!!  Manual route — it takes about a minute:"
  echo "!!    Keychain Access → Certificate Assistant → Create a Certificate…"
  echo "!!    Name: $NAME   Identity Type: Self Signed Root"
  echo "!!    Certificate Type: Code Signing   (tick 'Let me override defaults')"
  exit 1
fi

echo "==> Marking it trusted for code signing."
echo "    This one usually shows a GUI authorisation prompt. Approve it."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/ss.crt" 2>/dev/null || {
  echo "!!  Trust step failed or was cancelled — the certificate is imported but"
  echo "!!  may not be usable yet. In Keychain Access: login → Certificates →"
  echo "!!  '$NAME' → Trust → Code Signing: Always Trust."
}

echo
echo "==> Result:"
if has_identity; then
  security find-identity -v -p codesigning | grep "$NAME"
  echo
  echo "Done. Now run:  ./build.sh --install"
  echo "Grant Screen Recording once — it will stick across rebuilds from now on."
else
  echo "The identity is in the keychain but not showing as valid for code signing."
  echo "Open Keychain Access → login → Certificates → '$NAME' →"
  echo "Trust → Code Signing: Always Trust, then re-run this script."
  exit 1
fi

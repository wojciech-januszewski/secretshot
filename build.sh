#!/bin/bash
# Builds SecretShot.app. Works with Command Line Tools only — no Xcode needed.
#   ./build.sh            → build to ./build/SecretShot.app
#   ./build.sh --install  → also copy into ~/Applications and relaunch
#   ./build.sh --install /Applications → system-wide (needs sudo)
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="SecretShot"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Compiling (release)…"
swift build -c release --disable-sandbox

echo "==> Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Prefer a stable local identity: ad-hoc signatures get a fresh cdhash on every
# build, which invalidates the TCC grant and re-prompts for Screen Recording.
# Create one with ./Tools/make-signing-cert.sh.
IDENTITY="SecretShot Dev"
# Try the real identity first and fall back on failure, rather than pre-checking
# with `find-identity -v` — an imported-but-not-yet-trusted certificate is missing
# from that list yet can still sign.
if codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "==> Signed with '$IDENTITY' — Screen Recording will persist across rebuilds."
else
  echo "==> Signing (ad-hoc) — Screen Recording will re-prompt after each rebuild."
  echo "    Run ./Tools/make-signing-cert.sh once to stop that."
  codesign --force --deep --sign - "$APP" 2>/dev/null
fi

if [[ "${1:-}" == "--install" ]]; then
  # ~/Applications by default: no sudo, and Screen Recording permission sticks
  # to a stable path instead of being re-prompted on every rebuild in ./build.
  DEST="${2:-$HOME/Applications}"
  # Braces are load-bearing: "$DEST…" glues the multibyte ellipsis onto the
  # variable name and bash reports DEST… as unbound.
  echo "==> Installing to ${DEST}…"
  mkdir -p "$DEST"
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "$DEST/$APP_NAME.app"
  cp -R "$APP" "$DEST/$APP_NAME.app"
  open "$DEST/$APP_NAME.app"
  echo "==> Running from $DEST."
else
  echo "==> Built: $APP"
  echo "    Run it with: open $APP"
fi

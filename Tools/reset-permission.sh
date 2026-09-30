#!/bin/bash
# Clears SecretShot's Screen Recording grant so macOS re-registers it.
#
# Needed whenever the app's code signature changes identity (ad-hoc → self-signed,
# self-signed → Developer ID). TCC stores the grant against the signature that was
# current when you approved it; after a re-sign the old entry silently stops
# matching, and the toggle in System Settings looks ON while access is denied.
set -euo pipefail
BUNDLE_ID="dev.januszewski.secretshot"

echo "==> Resetting Screen Recording for $BUNDLE_ID"
tccutil reset ScreenCapture "$BUNDLE_ID"
pkill -x SecretShot 2>/dev/null || true
sleep 1
open "$HOME/Applications/SecretShot.app" 2>/dev/null || true
echo "==> Relaunched. Press ⌘⇧8, choose 'Open Settings', approve, then quit and reopen."

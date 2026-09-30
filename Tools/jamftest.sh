#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O Sources/SecretShot/Detectors.swift Sources/SecretShot/Scanner.swift \
  Sources/SecretShot/Redactor.swift Tools/JamfTest/main.swift -o build/jamftest
exec ./build/jamftest

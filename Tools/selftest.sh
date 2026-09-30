#!/bin/bash
# Compiles and runs the detection self-test against a synthetic admin-panel screenshot.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O \
  Sources/SecretShot/Detectors.swift \
  Sources/SecretShot/Scanner.swift \
  Sources/SecretShot/Redactor.swift \
  Tools/SelfTest/main.swift \
  -o build/selftest
exec ./build/selftest

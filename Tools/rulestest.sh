#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O Sources/SecretShot/Detectors.swift Sources/SecretShot/Scanner.swift \
  Sources/SecretShot/Redactor.swift Tools/RulesTest/main.swift -o build/rulestest
exec ./build/rulestest

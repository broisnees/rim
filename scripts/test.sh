#!/bin/zsh
# Runs every automated check: build, hardware probe, motion math, input-safety gate, performance.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release 2>&1 | grep -E "error:" && exit 1
BIN=.build/release/Rim
mkdir -p .build/tests
echo "== hardware";   $BIN --probe 2>&1 | grep -vE "Recognized|listening|frames:"
echo "== motion";     swiftc -O Sources/Rim/Motion.swift scripts/motion-tests/main.swift -o .build/tests/motion && .build/tests/motion
echo "== gestures";     $BIN --gesture-test
echo "== input safety"; $BIN --gate-test
echo "== performance";  $BIN --bench

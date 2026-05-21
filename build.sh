#!/bin/bash
# Builds a universal (arm64 + x86_64) binary so the same artefact runs on
# both Apple Silicon and Intel Macs. The two slices are compiled
# separately and stitched together with lipo.

set -euo pipefail
cd "$(dirname "$0")"

ARM="claude-usage-bar.arm64"
X86="claude-usage-bar.x86_64"
OUT="claude-usage-bar"

swiftc -O -target arm64-apple-macos11   main.swift -o "$ARM"
swiftc -O -target x86_64-apple-macos11 main.swift -o "$X86"
lipo -create -output "$OUT" "$ARM" "$X86"
rm -f "$ARM" "$X86"

echo "built: $(pwd)/$OUT"
file "$OUT"
echo "run:   ./$OUT"

#!/bin/bash
# Builds a universal (arm64 + x86_64) binary so the same artefact runs on
# both Apple Silicon and Intel Macs. The two slices are compiled
# separately and stitched together with lipo.

set -euo pipefail
cd "$(dirname "$0")"

ARM="claude-usage-bar.arm64"
X86="claude-usage-bar.x86_64"
OUT="claude-usage-bar"

# Scripts the binary must be able to restore by itself: self-update replaces
# only the binary, so a 0.5.x install has no sessions.sh in Resources and the
# old notification hooks. They are embedded as string literals.
./embed-scripts.sh > EmbeddedScripts.swift
SOURCES="main.swift Sessions.swift EmbeddedScripts.swift"

# shellcheck disable=SC2086
swiftc -O -target arm64-apple-macos12  $SOURCES -o "$ARM"
# shellcheck disable=SC2086
swiftc -O -target x86_64-apple-macos12 $SOURCES -o "$X86"
lipo -create -output "$OUT" "$ARM" "$X86"
rm -f "$ARM" "$X86"

echo "built: $(pwd)/$OUT"
file "$OUT"

# Wrap the bare binary in a .app bundle so it's launchable from
# Finder/Spotlight/Launchpad. The bare binary stays at the repo root for
# self-update and dev workflows; both ship in releases.
./package-app.sh

echo "run:   ./$OUT  (bare binary, dev mode)"
echo "       open './Claude Usage Bar.app'  (bundle)"

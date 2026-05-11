#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: scripts/package-agent-sim.sh <version> [output-dir]}"
VERSION="${VERSION#v}"
TAG="v${VERSION}"
OUT_DIR="${2:-release}"
BUILD_DIR=".build/arm64-apple-macosx/release"
STAGING="agent-sim-${TAG}-macOS-arm64"
ARCHIVE="agent-sim_${TAG}_macOS_arm64.tar.gz"
CHECKSUMS="agent-sim_${TAG}_checksums.txt"

rm -rf "$OUT_DIR" "$STAGING"
mkdir -p "$OUT_DIR" "$STAGING"

swift build -c release --arch arm64 --disable-sandbox --product agent-sim
strip -rSTx "$BUILD_DIR/agent-sim" || true

cp "$BUILD_DIR/agent-sim" "$STAGING/agent-sim"
cp -R "$BUILD_DIR/agent-sim_Baguette.bundle" "$STAGING/agent-sim_Baguette.bundle"

tar czf "$OUT_DIR/$ARCHIVE" "$STAGING"
(
    cd "$OUT_DIR"
    shasum -a 256 "$ARCHIVE" > "$CHECKSUMS"
)

rm -rf "$STAGING"
echo "$OUT_DIR/$ARCHIVE"
echo "$OUT_DIR/$CHECKSUMS"

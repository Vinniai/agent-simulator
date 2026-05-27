#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: scripts/package-agent-sim.sh <version> [output-dir]}"
VERSION="${VERSION#v}"
TAG="v${VERSION}"
OUT_DIR="${2:-release}"
BUILD_DIR=".build/arm64-apple-macosx/release"
STAGING="agent-simulator-${TAG}-macOS-arm64"
ARCHIVE="agent-simulator_${TAG}_macOS_arm64.tar.gz"
CHECKSUMS="agent-simulator_${TAG}_checksums.txt"

rm -rf "$OUT_DIR" "$STAGING"
mkdir -p "$OUT_DIR" "$STAGING"

swift build -c release --arch arm64 --disable-sandbox --product agent-sim
strip -rSTx "$BUILD_DIR/agent-sim" || true

cp "$BUILD_DIR/agent-sim" "$STAGING/agent-simulator"
# SPM names resource bundles `<package>_<target>.bundle` from the SPM
# package name (`agent-sim`), so the bundle stays `agent-sim_AgentSim.bundle`
# even though the shipped binary is renamed to `agent-simulator`. The
# postinstall resolves the bundle by that name beside the executable.
# Fall back to the legacy name so older tagged checkouts still package.
if [ -d "$BUILD_DIR/agent-sim_AgentSim.bundle" ]; then
    cp -R "$BUILD_DIR/agent-sim_AgentSim.bundle" "$STAGING/agent-sim_AgentSim.bundle"
else
    cp -R "$BUILD_DIR/agent-sim_Baguette.bundle" "$STAGING/agent-sim_Baguette.bundle"
fi

tar czf "$OUT_DIR/$ARCHIVE" "$STAGING"
(
    cd "$OUT_DIR"
    shasum -a 256 "$ARCHIVE" > "$CHECKSUMS"
)

rm -rf "$STAGING"
echo "$OUT_DIR/$ARCHIVE"
echo "$OUT_DIR/$CHECKSUMS"

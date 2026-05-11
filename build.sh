#!/bin/bash
set -e
cd "$(dirname "$0")"

# Pure-SPM build. Private frameworks resolve through the rpath flags +
# linkedFramework declarations in Package.swift.
swift build -c release

# Drop the binary at the workspace root so the Makefile / install scripts
# can use it directly.
cp -f .build/release/agent-sim ./agent-sim
echo "Build complete: ./agent-sim"

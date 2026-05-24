#!/bin/bash
set -e
cd "$(dirname "$0")"

# The iOS-Simulator side of the camera feature — see VirtualCamera/.
# Cross-compiled against the iphonesimulator SDK (fat: arm64 + x86_64),
# linker-signed adhoc. Staged into Sources/Baguette/Resources/VirtualCamera/
# so SPM bundles it as a `.copy` resource.
./VirtualCamera/build.sh
mkdir -p Sources/Baguette/Resources/VirtualCamera
cp -f VirtualCamera/VirtualCamera.dylib Sources/Baguette/Resources/VirtualCamera/

# Pure-SPM build. Private frameworks resolve through the rpath flags +
# linkedFramework declarations in Package.swift.
swift build -c release

# Drop the binary at the workspace root so the Makefile / install scripts
# can use it directly.
cp -f .build/release/agent-sim ./agent-sim
echo "Build complete: ./agent-sim"

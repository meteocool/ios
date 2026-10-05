#!/usr/bin/env bash
# The AR storm view's logic and shaders, checked on the Mac without a
# simulator: see tests/ARCheck.swift. MC_AR_FIXTURE=path/to/storm.mcvx also
# decodes a real volume.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
    meteocool/lib/Environment.swift meteocool/lib/NetworkHelper.swift \
    meteocool/AR/StormVolume.swift meteocool/AR/Colormaps.swift meteocool/AR/GeoFrame.swift \
    meteocool/AR/StormFeed.swift meteocool/AR/StormScene.swift meteocool/AR/StormShaders.swift \
    meteocool/AR/MapLink.swift \
    tests/ARCheck.swift -o "$scratch/check-ar"
"$scratch/check-ar"

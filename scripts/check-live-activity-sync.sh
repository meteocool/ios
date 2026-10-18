#!/usr/bin/env bash
# Run the real manager and URLSession in iOS Simulator, with controlled HTTP responses.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
udid="${MC_SIMULATOR_UDID:-$(xcrun simctl list devices booted --json | node -e 'let s=""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => console.log(Object.values(JSON.parse(s).devices).flat().find(d => d.name.startsWith("iPhone"))?.udid ?? ""));')}"
if [ -z "$udid" ]; then
    echo "Boot an iPhone simulator or set MC_SIMULATOR_UDID before running this check." >&2
    exit 1
fi
xcrun --sdk iphonesimulator swiftc -swift-version 6 -D DEBUG -parse-as-library \
    -target arm64-apple-ios18.0-simulator \
    meteocool/lib/Environment.swift meteocool/lib/NetworkHelper.swift \
    meteocool/lib/LiveActivityManager.swift Shared/RainActivityAttributes.swift \
    Shared/RainForecast.swift Shared/RadarImageStore.swift meteocool/AR/Colormaps.swift \
    tests/LiveActivityManagerCheck.swift -o "$scratch/check-live-activity-sync"
xcrun simctl spawn "$udid" "$scratch/check-live-activity-sync"

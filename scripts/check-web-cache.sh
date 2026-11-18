#!/usr/bin/env bash
# Exercise cache cleanup completion and expiration on an iOS simulator.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
: "${1:?Pass the UDID of a booted iOS 18+ simulator}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
app="$scratch/WebCacheCheck.app"
mkdir -p "$app"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.meteocool.WebCacheCheck</string>
<key>CFBundleExecutable</key><string>WebCacheCheck</string>
</dict></plist>
PLIST
xcrun --sdk iphonesimulator swiftc -swift-version 6 -parse-as-library \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios18.0-simulator \
    meteocool/lib/WebCache.swift tests/WebCacheCheck.swift -o "$app/WebCacheCheck"
xcrun simctl spawn "$1" "$app/WebCacheCheck"

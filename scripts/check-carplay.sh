#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
: "${1:?Pass the UDID of a booted iOS 18+ simulator}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
app="$scratch/CarPlayCheck.app"
mkdir -p "$app/en.lproj" "$app/nl.lproj"
cp meteocool/en.lproj/Localizable.strings "$app/en.lproj/"
cp meteocool/nl.lproj/Localizable.strings "$app/nl.lproj/"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.meteocool.CarPlayCheck</string>
  <key>CFBundleExecutable</key><string>CarPlayCheck</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
</dict></plist>
PLIST
xcrun --sdk iphonesimulator swiftc -swift-version 6 -parse-as-library \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios18.0-simulator \
    meteocool/CarPlay/CarPlayRainStatus.swift Shared/RainForecast.swift meteocool/AR/Colormaps.swift \
    Shared/AlertLanguage.swift meteocool/lib/Environment.swift meteocool/lib/NetworkHelper.swift \
    meteocool/NativeMap/Chrome/ConnectionRules.swift tests/CarPlayCheck.swift -o "$app/CarPlayCheck"
xcrun simctl spawn "$1" "$app/CarPlayCheck" -AppleLanguages '(en)'
xcrun simctl spawn "$1" "$app/CarPlayCheck" -AppleLanguages '(nl)'

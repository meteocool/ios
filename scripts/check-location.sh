#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
: "${1:?Pass the UDID of a booted iOS 18+ simulator}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
xcrun --sdk iphonesimulator swiftc -swift-version 6 -D DEBUG -parse-as-library \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios18.0-simulator \
    meteocool/lib/Environment.swift meteocool/lib/NetworkHelper.swift \
    meteocool/lib/LocationUpdater.swift tests/LocationUpdaterCheck.swift \
    -o "$scratch/check-location"
xcrun simctl spawn "$1" "$scratch/check-location"

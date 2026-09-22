#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
bash scripts/check-network.sh
node tests/geolocation-check.mjs
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc NotificationService/NotificationService.swift tests/NotificationServiceCheck.swift -o "$scratch/check-notification"
"$scratch/check-notification"

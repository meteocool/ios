#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc meteocool/lib/Environment.swift meteocool/lib/NetworkHelper.swift \
    tests/NetworkHelperCheck.swift -o "$scratch/check"
"$scratch/check"

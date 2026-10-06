#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
bash scripts/check-network.sh
bash scripts/check-ar.sh
node tests/geolocation-check.mjs
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc NotificationService/NotificationService.swift tests/NotificationServiceCheck.swift -o "$scratch/check-notification"
"$scratch/check-notification"
xcrun swiftc meteocool/lib/MapShare.swift tests/MapShareCheck.swift -o "$scratch/check-share"
"$scratch/check-share"
xcrun swiftc Shared/RainForecast.swift meteocool/AR/Colormaps.swift tests/RainForecastCheck.swift -o "$scratch/check-rain"
"$scratch/check-rain"
xcrun swiftc Shared/RainForecast.swift meteocool/AR/Colormaps.swift RainActivity/Widgets/RainForecast+Widgets.swift RainActivity/Widgets/PreviewCard.swift tests/WidgetCheck.swift -o "$scratch/check-widgets"
"$scratch/check-widgets"

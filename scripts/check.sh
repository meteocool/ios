#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
bash scripts/check-network.sh
bash scripts/check-ar.sh
node tests/geolocation-check.mjs
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc NotificationService/NotificationService.swift Shared/UserAgent.swift tests/NotificationServiceCheck.swift -o "$scratch/check-notification"
"$scratch/check-notification"
xcrun swiftc meteocool/lib/MapShare.swift tests/MapShareCheck.swift -o "$scratch/check-share"
"$scratch/check-share"
xcrun swiftc Shared/AlertLanguage.swift tests/AlertLanguageCheck.swift -o "$scratch/check-language"
"$scratch/check-language"
xcrun swiftc Shared/RainForecast.swift meteocool/AR/Colormaps.swift tests/RainForecastCheck.swift -o "$scratch/check-rain"
"$scratch/check-rain"
xcrun swiftc meteocool/NativeMap/RadarFrames.swift meteocool/NativeMap/RadarPixels.swift meteocool/NativeMap/NativeMapLink.swift meteocool/NativeMap/CoreStrings.swift meteocool/NativeMap/VectorTile.swift meteocool/NativeMap/Chrome/TimelinePhysics.swift meteocool/NativeMap/Chrome/ConnectionRules.swift meteocool/AR/Colormaps.swift tests/NativeMapCheck.swift -o "$scratch/check-native-map"
xcrun swiftc meteocool/NativeMap/Point/PointRules.swift meteocool/NativeMap/Point/ReverseGeocoder.swift meteocool/NativeMap/Point/ModelCompareRules.swift meteocool/NativeMap/Point/LightningRules.swift meteocool/NativeMap/Point/PrecipTypesRules.swift meteocool/NativeMap/CoreStrings.swift tests/NativeMapPointCheck.swift -o "$scratch/check-native-map-point"
"$scratch/check-native-map-point"
"$scratch/check-native-map"
xcrun swiftc meteocool/NativeMap/Storms/StormData.swift meteocool/NativeMap/Storms/StormSelection.swift meteocool/NativeMap/Storms/StormDrawing.swift meteocool/NativeMap/Storms/StormRules.swift meteocool/NativeMap/Storms/CloudHintRules.swift meteocool/NativeMap/Storms/CutAngle.swift meteocool/NativeMap/CoreStrings.swift tests/NativeMapStormsCheck.swift -o "$scratch/check-native-map-storms"
mkdir "$scratch/sweeps"
for quantity in DBZH VRADH; do gunzip -c "tests/fixtures/sweeps/$quantity.mcsw" > "$scratch/sweeps/$quantity.mcsw"; done
xcrun swiftc meteocool/NativeMap/Sites/SiteSweepRules.swift meteocool/NativeMap/Storms/RadarSites.swift tests/NativeMapSitesCheck.swift -o "$scratch/check-native-map-sites"
"$scratch/check-native-map-sites" "$scratch/sweeps"
xcrun swiftc meteocool/NativeMap/Stations/StationRules.swift tests/NativeMapStationsCheck.swift -o "$scratch/check-native-map-stations"
"$scratch/check-native-map-stations"
"$scratch/check-native-map-storms"
xcrun swiftc Shared/RainForecast.swift meteocool/AR/Colormaps.swift RainActivity/Widgets/RainForecast+Widgets.swift RainActivity/Widgets/PreviewCard.swift tests/WidgetCheck.swift -o "$scratch/check-widgets"
"$scratch/check-widgets"
xcrun swiftc meteocool/NativeMap/ThreeD/ThreeDMath.swift meteocool/NativeMap/ThreeD/ThreeDCamera.swift meteocool/NativeMap/ThreeD/ThreeDClouds.swift meteocool/NativeMap/ThreeD/ThreeDFraming.swift meteocool/NativeMap/ThreeD/ThreeDStyle.swift meteocool/NativeMap/ThreeD/CellVolume.swift meteocool/AR/StormVolume.swift meteocool/AR/Colormaps.swift tests/NativeMapThreeDCheck.swift -o "$scratch/check-native-map-3d"
"$scratch/check-native-map-3d"

#!/usr/bin/env bash
# Render the production Radar Map widget and check its configured rows and map area.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
scratch="$(mktemp -d)"
output="${1:-$(mktemp -d /tmp/meteocool-radar-widget.XXXXXX)}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
udid="${MC_SIMULATOR_UDID:-$(xcrun simctl list devices booted --json | node -e 'let s=""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => console.log(Object.values(JSON.parse(s).devices).flat().find(d => d.name.startsWith("iPhone"))?.udid ?? ""));')}"
if [ -z "$udid" ]; then
    udid="$(xcrun simctl list devices available | rg 'iPhone ' | tail -1 | rg -o '[0-9A-F-]{36}')"
    xcrun simctl boot "$udid"
fi
trap 'xcrun simctl uninstall "$udid" org.meteocool.radar-widget-check >/dev/null 2>&1 || true; rm -rf "$scratch"' EXIT
xcrun simctl bootstatus "$udid" -b >/dev/null
app="$scratch/RadarWidgetCheck.app"
mkdir -p "$app"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 6 -sdk "$sdk" \
    -target arm64-apple-ios18.0-simulator \
    meteocool/NativeMap/{RadarFrames,RadarWindow,RadarCoverage,RadarPixels,RadarTileStore,RadarCompositor,NativeMapEndpoints}.swift \
    Shared/*.swift meteocool/AR/Colormaps.swift \
    meteocool/lib/Environment.swift meteocool/lib/NetworkHelper.swift \
    RainActivity/RainChart.swift RainActivity/Widgets/{RadarMapWidget,RadarMapLayout,RadarMapImage,NativeWidgetMap,RainPlacesWidget,RainClockWidget,RainEntry,WidgetParts,WidgetStore,WidgetPlace,WidgetOptions,WidgetIntents,PreviewCard,RainForecast+Widgets}.swift \
    tests/WidgetReviewCheck.swift tests/NativeWidgetMapCheck.swift tests/RadarMapLayoutCheck.swift \
    -o "$app/RadarWidgetCheck"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.meteocool.radar-widget-check</string>
<key>CFBundleExecutable</key><string>RadarWidgetCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>Radar Widget Check</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
cp meteocool/NativeMap/radar-coverage.json "$app/"
cp -R RainActivity/en.lproj RainActivity/de.lproj "$app/"
xcrun simctl install "$udid" "$app"
native_args=()
if [ "${MC_NATIVE_WIDGET_CHECK:-0}" = 1 ]; then native_args=(--native); fi
if [ "${MC_NATIVE_WIDGET_CHECK:-0}" = only ]; then native_args=(--native --native-only); fi
if [ "${MC_WIDGET_REVIEW_ONLY:-0}" = 1 ]; then native_args=(--review-only); fi
for language in en de; do
    locale="en_US"
    if [ "$language" = de ]; then locale="de_DE"; fi
    xcrun simctl launch --console --terminate-running-process "$udid" \
        org.meteocool.radar-widget-check -AppleLanguages "($language)" -AppleLocale "$locale" ${native_args[@]+"${native_args[@]}"}
done
container="$(xcrun simctl get_app_container "$udid" org.meteocool.radar-widget-check data)"
for language in en de; do
    mkdir -p "$output/$language"
    cp -R "$container/Documents/radar-widget-$language/." "$output/$language/"
done
node - "$output" <<'JS'
const fs = require('node:fs');
let failures = 0;
for (const language of ['en', 'de']) {
  const report = JSON.parse(fs.readFileSync(`${process.argv[2]}/${language}/report.json`));
  for (const failure of report.failures) console.error(`${language}: ${failure}`);
  console.log(`${language} map heights: ${JSON.stringify(report.mapHeights)}`);
  failures += report.failures.length;
}
console.log(`Render evidence: ${process.argv[2]}`);
process.exitCode = failures ? 1 : 0;
JS

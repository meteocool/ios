#!/usr/bin/env bash
# Simulator render checks of the actual SwiftUI content, with OCR of its text.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
scratch="$(mktemp -d)"
output="${1:-$(mktemp -d /tmp/meteocool-activity-renders.XXXXXX)}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
udid="${MC_SIMULATOR_UDID:-$(xcrun simctl list devices booted --json | node -e 'let s=""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => console.log(Object.values(JSON.parse(s).devices).flat().find(d => d.name.startsWith("iPhone"))?.udid ?? ""));')}"
if [ -z "$udid" ]; then
    udid="$(xcrun simctl list devices available | rg 'iPhone ' | tail -1 | rg -o '[0-9A-F-]{36}')"
    xcrun simctl boot "$udid"
fi
trap 'xcrun simctl uninstall "$udid" org.meteocool.activity-layout-check >/dev/null 2>&1 || true; rm -rf "$scratch"' EXIT
xcrun simctl bootstatus "$udid" -b >/dev/null
app="$scratch/ActivityLayoutCheck.app"
mkdir -p "$app"
cat RainActivity/RainActivityWidget.swift tests/RainActivityLayoutCheck.swift > "$scratch/Check.swift"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 6 -sdk "$sdk" \
    -target arm64-apple-ios18.0-simulator \
    Shared/*.swift meteocool/AR/Colormaps.swift \
    meteocool/lib/Environment.swift meteocool/lib/NetworkHelper.swift \
    RainActivity/RainChart.swift RainActivity/Widgets/*.swift "$scratch/Check.swift" \
    -o "$app/ActivityLayoutCheck"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.meteocool.activity-layout-check</string>
<key>CFBundleExecutable</key><string>ActivityLayoutCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>Activity Layout Check</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
PLIST
cp -R RainActivity/en.lproj RainActivity/de.lproj "$app/"
xcrun simctl install "$udid" "$app"
for language in en de; do
    activity_locale="en_US"
    if [ "$language" = de ]; then activity_locale="de_DE"; fi
    xcrun simctl launch --console --terminate-running-process "$udid" \
        org.meteocool.activity-layout-check -AppleLanguages "($language)" -AppleLocale "$activity_locale"
done
container="$(xcrun simctl get_app_container "$udid" org.meteocool.activity-layout-check data)"
cp -R "$container/Documents/en" "$container/Documents/de" "$output/"
node - "$output" <<'JS'
const fs = require('node:fs');
let failures = 0;
for (const language of ['en', 'de']) {
  const report = JSON.parse(fs.readFileSync(`${process.argv[2]}/${language}/report.json`));
  console.log(`${language}: ${report.results.length} rendered cases, ${report.failures.length} failures`);
  for (const failure of report.failures.slice(0, 8)) console.error(failure);
  failures += report.failures.length;
}
console.log(`Render evidence: ${process.argv[2]}`);
process.exitCode = failures ? 1 : 0;
JS

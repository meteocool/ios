#!/usr/bin/env bash
# Build a signed device build and install it over USB/Wi-Fi with devicectl.
# Requires a valid Apple Developer team in Config/Base.xcconfig or Local.xcconfig.
#
#   ./scripts/device.sh                 # first connected device
#   ./scripts/device.sh <DEVICE-UDID>   # a specific one
source "$(dirname "$0")/_common.sh"

preflight
regenerate

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
    step "Looking for a connected device"
    DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ {print $(NF-1); exit}')"
    [ -n "$DEVICE" ] || fail "no connected device — run: xcrun devicectl list devices"
fi
info "device $DEVICE"

step "Building signed device build"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Debug \
    -destination "id=$DEVICE" \
    -derivedDataPath "$BUILD_DIR/device" \
    -allowProvisioningUpdates \
    build

APP="$(find "$BUILD_DIR/device/Build/Products" -name "$APP_NAME.app" -maxdepth 2 | head -1)"
[ -n "$APP" ] || fail "built app not found"

step "Installing to device"
xcrun devicectl device install app --device "$DEVICE" "$APP"

ok "$APP_NAME installed on $DEVICE"

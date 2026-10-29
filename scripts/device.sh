#!/usr/bin/env bash
# Build a signed device build and install it over USB/Wi-Fi with devicectl.
# Requires a valid Apple Developer team in Config/Base.xcconfig or Local.xcconfig.
#
#   ./scripts/device.sh                 # first connected device
#   ./scripts/device.sh <DEVICE-UDID>   # a specific one
#   ./scripts/device.sh <DEVICE-UDID> SETTING=value ...   # extra build settings
#   CONFIGURATION=Release ./scripts/device.sh ...         # an optimised build
#
# Signing with a personal team (Local.xcconfig) also needs the capabilities
# only the meteocool team has left out, e.g.:
#   CODE_SIGN_ENTITLEMENTS=$PWD/build/local-empty.entitlements
source "$(dirname "$0")/_common.sh"

preflight
regenerate

DEVICE="${1:-}"
[ $# -gt 0 ] && shift
CONFIG="${CONFIGURATION:-Debug}"
if [ -z "$DEVICE" ]; then
    step "Looking for a connected device"
    # Newer devicectl lists simulators too, and adds a Reality column:
    # the first physical device that is connected, or paired over Wi-Fi.
    DEVICE="$(xcrun devicectl list devices 2>/dev/null | grep -v 'simulated' | grep -E 'connected|available' \
        | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}|[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1)"
    [ -n "$DEVICE" ] || fail "no connected device — run: xcrun devicectl list devices"
fi
info "device $DEVICE"

step "Building signed device build"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "id=$DEVICE" \
    -derivedDataPath "$BUILD_DIR/device" \
    -allowProvisioningUpdates \
    ${1+"$@"} \
    build

APP="$BUILD_DIR/device/Build/Products/$CONFIG-iphoneos/$APP_NAME.app"
[ -d "$APP" ] || APP=""
[ -n "$APP" ] || fail "built app not found"

step "Installing to device"
xcrun devicectl device install app --device "$DEVICE" "$APP"

ok "$APP_NAME installed on $DEVICE"

#!/usr/bin/env bash
# Build, boot a simulator, install and launch. Prints the app's stdout/stderr.
source "$(dirname "$0")/_common.sh"

preflight
regenerate

step "Resolving simulator"
UDID="$(booted_simulator)"
info "using $UDID"

step "Building for simulator"
# Ad hoc signed, not unsigned: SpringBoard refuses to draw the launch screen
# of an unsigned app (black until the app's first frame), and only a signed
# build gets the app group the Live Activity and widgets share.
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination "id=$UDID" \
    -derivedDataPath "$BUILD_DIR/derived" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    build

APP="$(find "$BUILD_DIR/derived/Build/Products" -name "$APP_NAME.app" -maxdepth 2 | head -1)"
[ -n "$APP" ] || fail "built app not found under $BUILD_DIR/derived/Build/Products"

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist")"

step "Installing $BUNDLE_ID"
xcrun simctl install "$UDID" "$APP"

step "Launching (ctrl-c to detach)"
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID"

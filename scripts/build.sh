#!/usr/bin/env bash
# Unsigned simulator build. Needs no certificates, provisioning or Xcode UI.
# Use it for fast compile checks while editing code.
source "$(dirname "$0")/_common.sh"

preflight
regenerate

step "Building $SCHEME (unsigned, iOS Simulator)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$BUILD_DIR/derived" \
    CODE_SIGNING_ALLOWED=NO \
    build "$@"

ok "$SCHEME built"

#!/usr/bin/env bash
# Fast, unsigned simulator build. No certificates, no provisioning, no Xcode UI.
# This is the loop to use while iterating on code.
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

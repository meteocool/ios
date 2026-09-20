#!/usr/bin/env bash
# Run the UI test suite on a simulator.
source "$(dirname "$0")/_common.sh"

preflight
regenerate

step "Resolving simulator"
UDID="$(booted_simulator)"

step "Testing $SCHEME"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination "id=$UDID" \
    -derivedDataPath "$BUILD_DIR/derived" \
    CODE_SIGNING_ALLOWED=NO \
    test "$@"

ok "tests passed"

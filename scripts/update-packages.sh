#!/usr/bin/env bash
# Resolves Swift package dependencies to the newest versions project.yml allows
# and writes the pins to ./Package.resolved.
# ./Package.resolved is the checked-in copy of the pins, because the generated
# workspace is not in the repo.
source "$(dirname "$0")/_common.sh"

preflight

regenerate

step "Resolving to latest allowed versions"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -derivedDataPath "$BUILD_DIR/derived" \
    -resolvePackageDependencies

RESOLVED="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
[ -f "$RESOLVED" ] || fail "no Package.resolved produced"

if cmp -s "$RESOLVED" Package.resolved; then
    ok "already up to date"
else
    cp "$RESOLVED" Package.resolved
    step "Updated pins"
    git --no-pager diff -- Package.resolved || true
    ok "Package.resolved updated — commit it"
fi

#!/usr/bin/env bash
# Resolve Swift package dependencies to the newest versions allowed by
# project.yml and write the new pins back to ./Package.resolved (which is the
# checked-in source of truth, because the generated workspace is not).
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

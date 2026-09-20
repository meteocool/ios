#!/usr/bin/env bash
# Clean release pipeline: regenerate → archive → export a signed App Store .ipa.
#
# Upload is intentionally left to fastlane, which already owns the build-number
# bump and TestFlight submission:
#
#     bundle exec fastlane beta
#
source "$(dirname "$0")/_common.sh"

ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/Export"

step "Pre-flight"
preflight
TEAM_ID="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ DEVELOPMENT_TEAM =/ {print $2; exit}')"
[ -n "$TEAM_ID" ] || fail "DEVELOPMENT_TEAM is unset — set it in Config/Base.xcconfig or Local.xcconfig"
info "signing with team $TEAM_ID"
security find-identity -v -p codesigning | grep -q "Apple Distribution\|iPhone Distribution" || \
    info "warning: no Apple Distribution identity in the login keychain; export may fail"

step "Regenerating project"
xcodegen generate

rm -rf "$BUILD_DIR/$APP_NAME.xcarchive" "$EXPORT_PATH"
mkdir -p "$BUILD_DIR"

step "Archiving (Release)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$BUILD_DIR/derived-release" \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    archive

step "Exporting signed .ipa"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -allowProvisioningUpdates

IPA="$(find "$EXPORT_PATH" -name '*.ipa' | head -1)"
[ -n "$IPA" ] || fail "no .ipa produced"

step "Verifying"
unzip -qo "$IPA" -d "$BUILD_DIR/ipa-check"
codesign -dv --verbose=4 "$BUILD_DIR/ipa-check/Payload/$APP_NAME.app" 2>&1 | grep -E 'Authority|TeamIdentifier'
rm -rf "$BUILD_DIR/ipa-check"

ok "$IPA"
info "upload with: bundle exec fastlane beta"

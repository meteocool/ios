# meteocool iOS Migration TODO

## Open Tasks (Priority)

1. **HIGH**: Add Base Map Layer picker to Settings (parity with LayerSwitcher)
2. **MEDIUM**: Review/update SwiftUI UI tests for current structure (if any failing)
3. **MEDIUM**: Verify builds in Xcode for iOS 18 and iOS 26 (Liquid Glass)
4. **MEDIUM**: Wire `Radar Color Map` setting to actual radar rendering/API path (currently persisted but functionally no-op)

---

## Manual Testing (Simulator/Device)

- [ ] Fresh install → complete onboarding → grant both permissions → verify location pin appears on map
- [ ] Verify Xcode console shows `POST: /post_location` with token (not "anon")
- [ ] Verify server receives registration (if backend accessible)
- [ ] Trigger rain alert → verify push received (physical device)
- [ ] Tap notification → verify app opens to correct location
- [ ] Receive push in background → verify banner appears
- [ ] Grant location only (deny notifications) → map works, no pushes expected
- [ ] Grant notifications only (deny location) → no pushes expected
- [ ] Revoke location after granting → app handles gracefully
- [ ] Revoke notifications after granting → settings toggle updates
- [ ] Kill app, relaunch → settings persist (no re-onboarding unless toggled)
- [ ] Change settings, kill app, relaunch → changes persist

---

## App Store / Release Prep

- [ ] App icons: all sizes in `Assets.xcassets`
- [ ] Screenshots: update for new SwiftUI UI (fastlane)
- [ ] Info.plist: location/notification usage descriptions
- [ ] Entitlements: push notification enabled for production
- [ ] Privacy manifest: required for App Store

---

## Build Verification

- [ ] `xcodebuild -scheme meteocool -configuration Release` succeeds
- [ ] Archive in Xcode succeeds
- [ ] Runs on physical device (not just simulator)
- [ ] iOS 18 deployment target correct

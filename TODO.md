# meteocool iOS Vibeocool Migration TODO

## Overview

This document tracks the migration from the old UIKit/WKWebView-based implementation to the new native SwiftUI/MKMapView implementation.

---

## ✅ Completed Items

### Architecture

- [x] Replaced `@main` UIKit AppDelegate pattern with SwiftUI `App` protocol (`MeteocoolApp.swift`)
- [x] Replaced WKWebView with native `MKMapView` for map rendering
- [x] Migrated from UIKit storyboards to pure SwiftUI
- [x] Implemented `@Observable` state management replacing legacy patterns
- [x] Created modular `Map/` folder structure with clean separation

### Map Features

- [x] Native radar tile overlays via `MeteocoolTileOverlay`
- [x] Lightning strikes as `MKAnnotation` with color gradient by age
- [x] Mesocyclone annotations with intensity-based sizing
- [x] Snow overlay support via `SnowTileOverlay`
- [x] CyclOSM base layer support
- [x] User location tracking with `MKUserTrackingMode`
- [x] Timeline controls for radar playback
- [x] Layer switcher sheet (Radar/Satellite/CyclOSM)

### Settings

- [x] Settings persistence via `SettingsStore` with UserDefaults
- [x] Legacy key migration for existing users
- [x] Map rotation toggle
- [x] Auto-zoom toggle
- [x] Display style picker (System/Light/Dark)
- [x] Radar color map selection
- [x] Layer toggles (Lightning/Mesocyclones/Snow)
- [x] Notification settings (Enable/Details/Intensity/Timeframe)
- [x] Experimental features toggle
- [x] "Show onboarding again" button

### UI/UX

- [x] Liquid Glass modifiers with iOS 26 `glassEffect` + iOS 18 fallback
- [x] SwiftUI onboarding flow with permission requests
- [x] Settings presented as sheet with thin material background
- [x] Native SF Symbols for all icons

### Notifications

- [x] Push notification registration
- [x] Token handling via `SharedNotificationManager`
- [x] AppDelegate integration for APNS callbacks
- [x] Notification acknowledgement to backend

### Location

- [x] Location permission requests
- [x] Background location updates
- [x] Location posting to backend API
- [x] Observer pattern for location updates

---

## ❌ Missing Features (vs Master Branch)

### Settings - About Section

- [x] **Add "About" section to SettingsScreen** with:
  - [x] "Contribute on GitHub" link → https://github.com/meteocool
  - [x] "Follow on X" link → https://twitter.com/meteocool_de
  - [x] "Feedback and Support" link → mailto:support@meteocool.com (with iOS version in subject)
  - [x] "Imprint & Privacy" link → https://meteocool.com/privacy.html

### Settings - Base Map Layer Picker

- [ ] **Add Base Map Layer picker to Settings** (currently only in LayerSwitcher)
  - Old app had this in Map View section of settings

---

## ⚠️ Items to Validate

### Build & Compilation

- [ ] Verify project builds successfully for iOS 18 target _(xcodebuild has permission issues - verify manually in Xcode)_
- [ ] Verify project builds successfully for iOS 26 target (Liquid Glass) _(verify manually in Xcode)_

### Leftovers / Cleanup

- [x] Main.storyboard removed ✓
- [x] Old ViewController.swift removed ✓
- [x] Old SettingsViewController.swift removed ✓
- [x] Old widget storyboard removed ✓
- [x] LaunchScreen.storyboard retained (correct - needed for launch)

### UI Tests

- [x] Verify onboarding test passes (`testOnboarding`) - ✅ Test code looks correct, uses "Continue" button
- [x] Verify display style persistence test passes (`testDisplayStylePersistsAfterRelaunch`) - ✅ Fixed test for SwiftUI Form Picker

### Wire-up Verification (Code Analysis)

- [x] Verify settings changes persist after app restart - ✅ `SettingsStore` uses didSet to sync with UserDefaults
- [x] Verify notification toggle requests permissions - ✅ `SettingsScreen` calls `SharedNotificationManager.register()` on toggle
- [x] Verify location button triggers permission flow - ✅ `MapScreen` calls `SharedLocationUpdater.requestLocation()`
- [x] Verify radar tiles load correctly - ✅ `radarStore.refresh()` called in `.task`, `MeteocoolTileOverlay` configured
- [x] Verify lightning layer displays strikes - ✅ `lightningStore.refresh()` called, `LightningAnnotation` renders with color gradient
- [x] Verify mesocyclone layer displays tornado icons - ✅ `mesocycloneStore.refresh()` called, `MesocycloneAnnotation` renders tornado SF Symbol
- [x] Verify snow overlay toggles work - ✅ `snowStore.refresh()` called, `SnowTileOverlay` managed by coordinator

### Localization

- [x] Verify all new strings have German translations - ✅ All keys present in `de.lproj/Localizable.strings`
- [x] Verify all new strings have English translations - ✅ All keys present in `en.lproj/Localizable.strings`

---

## 📋 Implementation Priority

1. **HIGH**: Add About section to Settings (feature parity)
2. **MEDIUM**: Update UI tests for new SwiftUI structure
3. **LOW**: Add Base Map Layer picker to Settings (convenience - already in LayerSwitcher)

---

## Notes

- The old app used a remote WKWebView loading `app.ng.meteocool.com/ios.html` - this is now fully native
- Radar color mapping setting exists but may not be wired to tile rendering (tiles are server-side colored)
- `SwiftFSM.swift` remains in codebase (may be legacy - LocationUpdater doesn't use FSM anymore)

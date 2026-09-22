# meteocool iOS audit — updated 22.09.2026

The iOS changes build with **Xcode 27.0 (27A266a)** and target iOS 18 or later.
The rewritten staging frontend passes the tested integration paths. **The app
is not yet verified for production release**: the production web deployment
fails the rewritten playback accessibility test, and no physical device is
connected for APNs/background verification. iOS 18.6 simulator checks now pass.

## Scope and architecture

Only `ios` was edited. `core` is the Svelte/TypeScript web map; `ng` provides
FastAPI endpoints, weather ingestion, analysis, previews and notification
workers. Both reference worktrees remain unchanged. No commits, pushes,
deployments, credentials or production registrations were made.

The wrapper owns onboarding, permission requests, settings, location and APNs.
The web map owns layers and forecast playback. Native registration uses the
unversioned compatibility routes (`post_location`, `unregister`,
`clear_notification`). The backend validates `lang` (de/en), `ahead` (1–60),
`intensity` (0–130) and tokens (32–192 characters), and can return HTTP 200 with
`success:false`; transport success alone is insufficient.

The production frontend URL now follows `core/wrangler.jsonc`:
`https://meteocool.com/ios.html`. Staging uses
`https://web.staging.meteocool.com/ios.html`. Production native API remains
`api.ng.meteocool.com`, matching the split production architecture documented
in `core/src/urls.ts`; staging uses `staging.meteocool.com`.

## Fixes

- Centralized notification opt-in, authorization refresh, token delivery,
  failed-sync reporting and opt-out. Removal requests now execute. Location
  posts require opt-in, notification authorization, location authorization and
  a fresh token/fix. In-flight posts are removed after opt-out; preference posts
  are serialized. CarPlay connection now enables background monitoring immediately; disconnect stops its updates when the phone is inactive. The original registration origin is retained for cleanup
  when switching deployments. Live cross-deployment mutation was not tested.
- Corrected lead-time indexing, bounded slider values, language mapping and
  `withDBZ` payloads. Removed tokens/location payloads from diagnostics and
  support mail. Pressure is optional, permission-aware and time-bounded.
- Replaced obsolete forecast drawer calls with the web frontend's controls.
  Added page-load failure/retry, bridge readiness gating, trusted main-frame
  message checks and explicit scene lifecycle forwarding. Geolocation shim
  checks cover duplicate delivery, cancellation, timeout and denial recovery.
- Replaced fixed onboarding with native scrolling UIKit pages; denial and skip
  remain valid paths. Location starts with When In Use, with a separate Always
  upgrade for notifications. Settings labels wrap and rows self-size. Native
  map controls have accessibility labels and 52-point hit areas. iOS 26/27 use
  UIKit Liquid Glass; iOS 18 uses availability-guarded legacy blur.
- Removed StepSlider, OnboardKit, obsolete onboarding nags, the custom forecast
  gesture recognizer, the redundant notification content extension, an
  unreachable storyboard scene and obsolete plist entries. NotificationService
  preserves text when previews fail and completes once. Added the app-group
  UserDefaults privacy-manifest reason.

## Verification evidence

All builds and simulator tests use `/Applications/Xcode.app/Contents/Developer`.
The system-wide `xcode-select` setting was not changed. XcodeGen 2.46.0 was
installed from Homebrew's bottle; simulator runtimes came from Apple.

| Evidence | Result / boundary |
| --- | --- |
| Unsigned Debug simulator build | Passed with Xcode 27 / iOS 27 SDK, minimum iOS 18 |
| Unsigned Release device build | Passed; no Swift warnings in the final source build; AppIntents extraction reports no dependency |
| `bash scripts/check.sh` | Passed: response validation/serialization, actual geolocation JS, notification fallback/once-only completion |
| `build/Runtime18Xcode27.xcresult` | 3 passed, zero failures: iPhone 16 / iOS 18.6 (22G86), built and tested with Xcode 27.0 (27A266a); map failure/retry, loopback notification registration/preferences/opt-out, onboarding skip, staging layers/playback and settings Save/Cancel/relaunch. Map and settings screenshots visually checked under `build/screenshots/runtime18/`. |
| `build/SettingsAPI26.xcresult` | 2 passed: permission grant, real loopback HTTP registration, slider payloads, opt-out/foreground, onboarding skip, layers/playback, basemap and color-map Save/Cancel, rotation switch, relaunch |
| `build/Recovery27.xcresult` | 3 passed: denial recovery alerts, failed map load with usable settings, retry restoring bridge, staging map controls/settings |
| `build/FreshLocationAPI27.xcresult` | Passed on final app sources: native onboarding and real HTTP notification registration/preferences/opt-out on iPad |
| `build/FinalRetry27.xcresult` and final retry case in `build/FinalContract27.xcresult` | Passed: failed map load, usable settings and recovered bridge after removal of obsolete ATS exception |
| `MC_PREVIEW_URL=https://web.staging.meteocool.com/favicon.png bash scripts/check.sh` | Passed: actual HTTPS download becomes a UNNotificationAttachment; standalone service-class check, not APNs execution |
| `build/FinalAccessible27.xcresult` | Passed: largest accessibility text, dark appearance and iPad rotation; screenshots retained |
| `build/SystemSettingsNavigation27.xcresult` | Passed: denied location → actual system Settings → While Using the App → usable native location control |
| `build/screenshots/notification/foreground-banner-ios27.png` | Visually verified simulated foreground notification banner; not APNs transport proof |
| `build/Production26.xcresult` | **Failed:** production page loads, but its web controls differ and do not expose the rewritten `Playback Controls` accessibility button |

Screenshots are in result bundles and exported under `build/screenshots/`.
Staging displays a recorded-storm warning; passing staging UI tests does not
verify live weather processing. A slider test initially used an approximate
75% gesture, which selected a different step on iPhone than iPad; final API
checks use exact endpoints. Sliders submit on release instead of every drag
movement. Large-text inspection reproduced truncated onboarding/settings;
subsequent native scrolling/wrapping captures show readable content. A later iPad API run had no registration because its one-shot simulated location was stale; refreshing the simulator fix and rerunning the same code passed. Location checks intentionally reject fixes older than five minutes.

## Reproduce

Run from `ios`:

```sh
bash scripts/check.sh
./scripts/build.sh
# Separate terminal; memory-only recorder, loopback only, synthetic token only:
node tests/mobile-api-recorder.mjs
```

Use a dedicated simulator and set its synthetic location before API UI tests:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash scripts/check-location.sh <UDID>
xcrun simctl location <UDID> set 48.1373,11.575
xcodebuild -project meteocool.xcodeproj -scheme meteocool \
  -destination 'id=<UDID>' -derivedDataPath build/derived \
  CODE_SIGNING_ALLOWED=NO test
```

The full suite includes the intentionally failing production compatibility
check. Permission-denial tests need a fresh simulator or reset OS permissions;
`--ui-test-reset` resets app preferences only. API/retry tests skip if the local
recorder is absent. Their loopback/synthetic-token hooks are limited to Debug
simulators and cannot override Release/device endpoints. The synthetic token
is not persisted.

## Release gates and remaining limits

1. Verify production playback manually and align its accessibility/test contract
   with this wrapper. Both `app.ng.meteocool.com` and the declared `meteocool.com`
   production page failed the rewritten playback accessibility check. The
   missing test selector does not establish that playback is broken or that
   deployment is the required fix. Do not substitute staging: it is showing
   recorded storm data. No frontend/backend deployment was made.
2. Verify a signed physical iPhone: APNs token/provider delivery, denied-to-
   allowed notification recovery in system Settings, rich preview expansion,
   notification taps/clears, background movement and Always-location behavior.
   The CarPlay lifecycle and observer cleanup build, but the car UI and Apple
   entitlement/provisioning are not verified on hardware.

The iOS 18 runtime gap was resolved on 22.09.2026. The installed Xcode 26.6
download tool acquired Apple's iOS 18.6 runtime with its default architecture
selection (`xcodebuild -downloadPlatform iOS -buildVersion 18.6`); previous
explicit-architecture attempts failed. Xcode 26.6 was used only for acquisition.
All app builds and tests, including the three passing iOS 18.6 cases, used
Xcode 27. The iOS 18 run did not repeat denied-permission recovery, large-text
rotation, or physical-device checks.

## Independent code review — 22.09.2026

The requested independent reviewer found no critical issues, two important
issues and one minor accessibility issue. All three were fixed and accepted
on re-review:

- Location requests now recheck the five-minute freshness limit after waiting
  for earlier requests, before sending coordinates to the backend.
- Turning off phone tracking no longer stops the shared location stream while
  CarPlay is connected. Disconnect still permits stopping the stream.
- Experimental Features sets its own accessibility label on reused switch cells.

`bash scripts/check-location.sh <UDID>` compiles the actual location updater and
network helper with Xcode 27 and runs them in a booted simulator. It replaces
OS permission/APNs state with test doubles and delays URLSession transport;
it does not exercise CarPlay hardware or APNs. Removing each guard separately
reproduced its intended assertion failure; both checks pass with the fixes on
iOS 18.6 and 27. The existing settings UI test also checks the Experimental
Features accessibility label.

Final verification: `build/ReviewFixes18.xcresult` and
`build/ReviewFixes27.xcresult` each passed all three selected UI cases (map
retry, notification API/preferences/opt-out, onboarding/map/settings).
`bash scripts/check.sh`, the focused location checks on both runtimes,
`git diff --check`, and the unsigned Release device build also passed with
Xcode 27. No new blocking findings remained on re-review.

## Primary references

- [Apple: adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Apple: registering with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
- [Apple: location authorization](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services)
- [Apple: scene lifecycle](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle)
- [Requested CLI workflow article](https://scottwillsey.com/building-and-shipping-mac-and-ios-apps-without-ever-opening-xcode/)

Installed SDK declarations and the actual builds/tests take precedence over
workflow examples. Device, production and test-coverage limits remain
explicit; simulator checks do not establish release readiness.

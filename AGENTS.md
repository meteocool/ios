# AI Agents Guide - meteocool iOS

Welcome, AI Agent! This document provides context and guidelines for working on the meteocool iOS repository.

## Project Overview

meteocool is an iOS application for rain radar and weather visualization.

- **Main App:** Native Swift 6 / SwiftUI with iOS 18+ deployment target.
- **Map View:** Native `MKMapView` integration with custom tile overlays for radar, snow, and satellite data.
- **Extensions:** Includes WidgetKit, Notification Service, and Notification Content extensions.

## Repository Structure

- `meteocool/`: Core application logic, UI components (SwiftUI), and state management.
  - `App/`: App-level state, entry points, and shared modifiers (`View+Glass.swift`).
  - `Map/`: Map integration (`MapView.swift`, `MapCoordinator.swift`), data stores, and overlays.
  - `Networking/`: API communication (`MeteocoolAPI.swift`).
  - `Settings/`: User configuration screens.
  - `onboarding/`: First-launch permission flows.
- `Widget/` & `WidgetKit/`: iOS Home Screen widget implementation.
- `NotificationService/` & `NotificationContent/`: Push notification handling and rich content display.
- `fastlane/`: Automation for builds and screenshots.
- `AppStore_Images/`: Design assets and screenshots.

## Technical Context

- **Language:** Swift 6 with strict concurrency checking.
- **Deployment Target:** iOS 18.0+
- **Frameworks:** SwiftUI, MapKit, Combine, WidgetKit.
- **State Management:** Uses `@Observable` macro (`AppState.swift`, `SettingsStore.swift`).
- **CI/CD:** Fastlane is used for automation.

## Swift 6 Gotchas

- **Sendable conformance:** Classes used in async contexts need `@unchecked Sendable` or full conformance.
- **Type inference:** Avoid passing generic types (like `Material`) to View extension methods with `some View` return types. Create dedicated methods instead.
- **@MainActor != async:** Don't use `await` on `@MainActor` functions unless they're also `async`.
- **iOS 26 glassEffect:** Use `.glassEffect(.regular, in: .rect(cornerRadius:))`, not `Material.interactive()`.

## Coding Standards & Conventions

- **Follow existing patterns:** Match the naming conventions and architectural patterns found in `meteocool/`.
- **UI:** Prefer SwiftUI for new UI components unless legacy integration requires UIKit.
- **Localization:** Ensure all user-facing strings are localized (check `de.lproj` and `en.lproj`).
- **Safety:** Be mindful of background location services and notification permissions, as these are critical features.

## Instructions for Agents

1. **Context First:** Always read `AppState.swift` and `MeteocoolApp.swift` to understand the current application flow before suggesting architectural changes.
2. **Map Integration:** The map is native MKMapView with custom overlays. See `MapView.swift` and `MapCoordinator.swift`.
3. **Adding Files:** Creating a `.swift` file is NOT enough—you must add it to `project.pbxproj` (PBXBuildFile, PBXFileReference, PBXGroup, and PBXSourcesBuildPhase sections).
4. **Testing:** Check `meteocoolUITests` for existing UI tests. SwiftUI Pickers render as buttons, use `NSPredicate` matching.
5. **Fastlane:** If modifying build processes, consult `fastlane/Fastfile`.
6. **Localization:** All user-facing strings must be in both `de.lproj` and `en.lproj` Localizable.strings.

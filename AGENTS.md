# AI Agents Guide - meteocool iOS

Welcome, AI Agent! This document provides context and guidelines for working on the meteocool iOS repository.

## Project Overview
meteocool is an iOS application for rain radar and weather visualization.
- **Main App:** Native Swift 5 / SwiftUI.
- **Map View:** The map and data visualization are maintained in the [meteocool/core](https://github.com/meteocool/core) repository (ES6/Svelte) and likely embedded via a web view or similar.
- **Extensions:** Includes WidgetKit, Notification Service, and Notification Content extensions.

## Repository Structure
- `meteocool/`: Core application logic, UI components (SwiftUI), and state management.
  - `App/`: App-level state and entry points.
  - `Map/`: Map integration logic.
  - `Networking/`: API communication.
  - `Settings/`: User configuration.
- `Widget/` & `WidgetKit/`: iOS Home Screen widget implementation.
- `NotificationService/` & `NotificationContent/`: Push notification handling and rich content display.
- `fastlane/`: Automation for builds and screenshots.
- `AppStore_Images/`: Design assets and screenshots.

## Technical Context
- **Language:** Swift 5+
- **Frameworks:** SwiftUI (primarily), Combine (likely for state), WidgetKit.
- **State Management:** Uses `AppState.swift` and `SettingsStore.swift`.
- **CI/CD:** Fastlane is used for automation.

## Coding Standards & Conventions
- **Follow existing patterns:** Match the naming conventions and architectural patterns found in `meteocool/`.
- **UI:** Prefer SwiftUI for new UI components unless legacy integration requires UIKit.
- **Localization:** Ensure all user-facing strings are localized (check `de.lproj` and `en.lproj`).
- **Safety:** Be mindful of background location services and notification permissions, as these are critical features.

## Instructions for Agents
1. **Context First:** Always read `AppState.swift` and `MeteocoolApp.swift` to understand the current application flow before suggesting architectural changes.
2. **Map Interaction:** Remember that core map logic resides in a separate repository. Changes to map *behavior* may need to happen there, while *integration* happens here.
3. **Testing:** Check `meteocoolUITests` for existing UI tests and add new ones for significant features.
4. **Fastlane:** If modifying build processes, consult `fastlane/Fastfile`.

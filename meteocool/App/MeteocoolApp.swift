import SwiftUI

@main
struct MeteocoolApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @State private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            MapScreen()
                .environment(appState)
                .environment(settings)
                .task {
                    await DisplayStyle.applyToAllWindows(settings.displayStyle)
                }
                .onChange(of: settings.displayStyle) { _, newValue in
                    Task { @MainActor in
                        DisplayStyle.applyToAllWindows(newValue)
                    }
                }
        }
    }
}

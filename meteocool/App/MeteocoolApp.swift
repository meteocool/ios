import SwiftUI

@main
struct MeteocoolApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @State private var settings = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            MapScreen()
                .environment(appState)
                .environment(settings)
                .task {
                    DisplayStyle.applyToAllWindows(settings.displayStyle)
                }
                .onChange(of: settings.displayStyle) { _, newValue in
                    DisplayStyle.applyToAllWindows(newValue)
                }
        }
    }
}

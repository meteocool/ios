import SwiftUI

struct SettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section(LocalizedStringKey("settings_section_map")) {
                Toggle(LocalizedStringKey("Two-Finger Map Rotation"), isOn: Binding(
                    get: { settings.mapRotation },
                    set: { settings.mapRotation = $0 }
                ))
                Toggle(LocalizedStringKey("Auto-Zoom After Start"), isOn: Binding(
                    get: { settings.autoZoom },
                    set: { settings.autoZoom = $0 }
                ))
                Picker(LocalizedStringKey("settings_display_style"), selection: Binding(
                    get: { settings.displayStyle },
                    set: { settings.displayStyle = $0 }
                )) {
                    ForEach(DisplayStyle.allCases) { style in
                        Text(LocalizedStringKey(style.labelKey)).tag(style)
                    }
                }
                Picker(LocalizedStringKey("Radar Color Map"), selection: Binding(
                    get: { settings.radarColorMapping },
                    set: { settings.radarColorMapping = $0 }
                )) {
                    ForEach(RadarColorMapping.allCases) { mapping in
                        Text(LocalizedStringKey(mapping.labelKey)).tag(mapping)
                    }
                }
            }

            Section(LocalizedStringKey("settings_section_layers")) {
                Toggle(LocalizedStringKey("⚡️ Lightning"), isOn: Binding(
                    get: { settings.layerLightning },
                    set: { settings.layerLightning = $0 }
                ))
                Toggle(LocalizedStringKey("🌀 Mesocyclones"), isOn: Binding(
                    get: { settings.layerMesocyclones },
                    set: { settings.layerMesocyclones = $0 }
                ))
                Toggle(LocalizedStringKey("snow"), isOn: Binding(
                    get: { settings.layerSnow },
                    set: { settings.layerSnow = $0 }
                ))
            }

            Section(LocalizedStringKey("settings_section_notifications")) {
                Toggle(LocalizedStringKey("Enable Notifications"), isOn: Binding(
                    get: { settings.notificationsEnabled },
                    set: { settings.notificationsEnabled = $0 }
                ))
                Toggle(LocalizedStringKey("Show Meteorological Details"), isOn: Binding(
                    get: { settings.notificationShowDbz },
                    set: { settings.notificationShowDbz = $0 }
                ))
                Stepper("\(NSLocalizedString("Intensity Threshold", comment: "")): \(settings.notificationIntensity)", value: Binding(
                    get: { settings.notificationIntensity },
                    set: { settings.notificationIntensity = $0 }
                ), in: 0...4)
                Stepper("\(NSLocalizedString("Notification Timeframe", comment: "")): \(settings.notificationTimeBefore + 1) x 5 min", value: Binding(
                    get: { settings.notificationTimeBefore },
                    set: { settings.notificationTimeBefore = $0 }
                ), in: 0...6)
            }

            Section(LocalizedStringKey("settings_section_advanced")) {
                Toggle(LocalizedStringKey("experimental_features"), isOn: Binding(
                    get: { settings.experimentalFeatures },
                    set: { settings.experimentalFeatures = $0 }
                ))
                Button(LocalizedStringKey("show_onboarding_again")) {
                    settings.onboardingCompleted = false
                }
            }
        }
        .navigationTitle(LocalizedStringKey("Settings"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close")
            }
        }
        .onChange(of: settings.notificationsEnabled) { _, newValue in
            guard newValue else { return }
            Task {
                try? await SharedNotificationManager.register()
            }
        }
    }
}

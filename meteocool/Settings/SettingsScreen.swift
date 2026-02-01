import SwiftUI

struct SettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        
        Form {
            Section(LocalizedStringKey("settings_section_map")) {
                Toggle(LocalizedStringKey("Two-Finger Map Rotation"), isOn: $settings.mapRotation)
                Toggle(LocalizedStringKey("Auto-Zoom After Start"), isOn: $settings.autoZoom)
                Picker(LocalizedStringKey("settings_display_style"), selection: $settings.displayStyle) {
                    ForEach(DisplayStyle.allCases) { style in
                        Text(LocalizedStringKey(style.labelKey)).tag(style)
                    }
                }
                Picker(LocalizedStringKey("Radar Color Map"), selection: $settings.radarColorMapping) {
                    ForEach(RadarColorMapping.allCases) { mapping in
                        Text(LocalizedStringKey(mapping.labelKey)).tag(mapping)
                    }
                }
            }

            Section(LocalizedStringKey("settings_section_layers")) {
                Toggle(LocalizedStringKey("⚡️ Lightning"), isOn: $settings.layerLightning)
                Toggle(LocalizedStringKey("🌀 Mesocyclones"), isOn: $settings.layerMesocyclones)
                Toggle(LocalizedStringKey("snow"), isOn: $settings.layerSnow)
            }

            Section(LocalizedStringKey("settings_section_notifications")) {
                Toggle(LocalizedStringKey("Enable Notifications"), isOn: $settings.notificationsEnabled)
                Toggle(LocalizedStringKey("Show Meteorological Details"), isOn: $settings.notificationShowDbz)
                Stepper("\(NSLocalizedString("Intensity Threshold", comment: "")): \(settings.notificationIntensity)", value: $settings.notificationIntensity, in: 0...4)
                Stepper("\(NSLocalizedString("Notification Timeframe", comment: "")): \(settings.notificationTimeBefore + 1) x 5 min", value: $settings.notificationTimeBefore, in: 0...6)
            }

            Section(LocalizedStringKey("settings_section_advanced")) {
                Toggle(LocalizedStringKey("experimental_features"), isOn: $settings.experimentalFeatures)
                Button(LocalizedStringKey("show_onboarding_again")) {
                    settings.onboardingCompleted = false
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle(LocalizedStringKey("Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .font(.title2)
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

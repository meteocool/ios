import SwiftUI
import UIKit
import UserNotifications

struct SettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var showPermissionDeniedAlert = false
    @State private var isSyncingPermission = false

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
                VStack(alignment: .leading) {
                    Text("\(NSLocalizedString("Notification Timeframe", comment: "")): \((settings.notificationTimeBefore + 1) * 5) min")
                    Slider(
                        value: Binding(
                            get: { Double(settings.notificationTimeBefore) },
                            set: { settings.notificationTimeBefore = Int($0.rounded()) }
                        ),
                        in: 0...8,
                        step: 1
                    ) {
                        Text(LocalizedStringKey("Notification Timeframe"))
                    } minimumValueLabel: {
                        Text("5")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("45")
                            .font(.caption)
                    }
                }
            }

            Section(LocalizedStringKey("settings_section_advanced")) {
                Toggle(LocalizedStringKey("experimental_features"), isOn: $settings.experimentalFeatures)
                Button(LocalizedStringKey("show_onboarding_again")) {
                    settings.onboardingCompleted = false
                }
            }

            Section(LocalizedStringKey("settings_section_about")) {
                Link(destination: URL(string: "https://github.com/meteocool")!) {
                    HStack {
                        Text(LocalizedStringKey("Contribute on GitHub"))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)

                Link(destination: URL(string: "https://twitter.com/meteocool_de")!) {
                    HStack {
                        Text(LocalizedStringKey("Follow on X"))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)

                Button {
                    openFeedbackEmail()
                } label: {
                    HStack {
                        Text(LocalizedStringKey("Feedback and Support"))
                        Spacer()
                        Image(systemName: "envelope")
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)

                Link(destination: URL(string: "https://meteocool.com/privacy.html")!) {
                    HStack {
                        Text(LocalizedStringKey("imprint_privacy"))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
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
                .accessibilityLabel(LocalizedStringKey("Close"))
            }
        }
        .task {
            // Sync notification toggle with actual OS permission state on appear
            isSyncingPermission = true
            await SharedNotificationManager.syncWithSystemPermission()
            isSyncingPermission = false
        }
        .onChange(of: settings.notificationsEnabled) { _, newValue in
            guard !isSyncingPermission else { return }
            guard newValue else {
                SharedNotificationManager.unregisterFromBackend()
                return
            }
            Task {
                let authorized = await SharedNotificationManager.checkAuthorizationStatus()
                if authorized {
                    // Already authorized, just register for push
                    UIApplication.shared.registerForRemoteNotifications()
                } else {
                    // Not yet authorized — check if we can still request
                    let center = UNUserNotificationCenter.current()
                    let currentSettings = await center.notificationSettings()
                    if currentSettings.authorizationStatus == .notDetermined {
                        // First time: request permission
                        try? await SharedNotificationManager.register()
                    } else {
                        // Denied: guide user to Settings.app
                        isSyncingPermission = true
                        settings.notificationsEnabled = false
                        isSyncingPermission = false
                        showPermissionDeniedAlert = true
                    }
                }
            }
        }
        .alert(LocalizedStringKey("notifications_disabled"), isPresented: $showPermissionDeniedAlert) {
            Button(LocalizedStringKey("Change in Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(LocalizedStringKey("Dismiss"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("notification_permission_denied_message"))
        }
    }

    private func openFeedbackEmail() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let subject = "iOS App Feedback (\(version))"
        guard let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "mailto:support@meteocool.com?subject=\(encodedSubject)") else { return }
        UIApplication.shared.open(url)
    }
}

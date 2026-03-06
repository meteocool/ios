import SwiftUI
import UIKit
import CoreMotion
import UserNotifications

struct SettingsScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var showPermissionDeniedAlert = false
    @State private var showBackgroundLocationAlert = false
    @State private var showAutoZoomPermissionAlert = false
    @State private var showMotionPermissionDeniedAlert = false
    @State private var isSyncingPermission = false
    @State private var isSyncingMotionPreference = false

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
                Toggle(LocalizedStringKey("settings_motion_sharing"), isOn: $settings.motionSharingEnabled)
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
            await revalidatePermissionBackedPreferences()
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
                    ensureBackgroundLocationPermissionForNotifications()
                } else {
                    // Not yet authorized — check if we can still request
                    let center = UNUserNotificationCenter.current()
                    let currentSettings = await center.notificationSettings()
                    if currentSettings.authorizationStatus == .notDetermined {
                        // First time: request permission
                        try? await SharedNotificationManager.register()
                        if settings.notificationsEnabled {
                            ensureBackgroundLocationPermissionForNotifications()
                        }
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
        .onChange(of: settings.motionSharingEnabled) { _, newValue in
            guard !isSyncingMotionPreference else { return }
            guard newValue else { return }
            requestMotionSharingPermissionIfNeeded()
        }
        .onChange(of: settings.notificationShowDbz) { _, _ in
            guard settings.notificationsEnabled else { return }
            SharedLocationUpdater.syncNotificationRegistrationNow()
        }
        .onChange(of: settings.notificationIntensity) { _, _ in
            guard settings.notificationsEnabled else { return }
            SharedLocationUpdater.syncNotificationRegistrationNow()
        }
        .onChange(of: settings.notificationTimeBefore) { _, _ in
            guard settings.notificationsEnabled else { return }
            SharedLocationUpdater.syncNotificationRegistrationNow()
        }
        .onChange(of: settings.autoZoom) { _, newValue in
            guard newValue else { return }
            ensureAutoZoomPermission()
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
        .alert(LocalizedStringKey("location_permission_required"), isPresented: $showBackgroundLocationAlert) {
            Button(LocalizedStringKey("Change in Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(LocalizedStringKey("Dismiss"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("enable_background_location_alert"))
        }
        .alert(LocalizedStringKey("location_permission_required"), isPresented: $showAutoZoomPermissionAlert) {
            Button(LocalizedStringKey("Change in Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(LocalizedStringKey("Dismiss"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("location_permission_autozoom"))
        }
        .alert(LocalizedStringKey("motion_permission_required"), isPresented: $showMotionPermissionDeniedAlert) {
            Button(LocalizedStringKey("Change in Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(LocalizedStringKey("Dismiss"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("motion_permission_denied_message"))
        }
    }

    @MainActor
    private func revalidatePermissionBackedPreferences() async {
        if settings.notificationsEnabled {
            let notificationsAuthorized = await SharedNotificationManager.checkAuthorizationStatus()
            if !notificationsAuthorized {
                disableNotificationsAndUnregister()
                showPermissionDeniedAlert = true
            } else if SharedLocationUpdater.authorizationStatus != .authorizedAlways {
                disableNotificationsAndUnregister()
                showBackgroundLocationAlert = true
            }
        }

        if settings.motionSharingEnabled, PressureManager.motionAuthorizationStatus != .authorized {
            setMotionSharingEnabled(false)
            showMotionPermissionDeniedAlert = true
        }
    }

    @MainActor
    private func ensureBackgroundLocationPermissionForNotifications() {
        switch SharedLocationUpdater.authorizationStatus {
        case .authorizedAlways:
            SharedLocationUpdater.syncNotificationRegistrationNow()
        case .notDetermined:
            SharedLocationUpdater.requestAuthorization({ _, _ in
                Task { @MainActor in
                    if SharedLocationUpdater.authorizationStatus == .authorizedAlways {
                        SharedLocationUpdater.syncNotificationRegistrationNow()
                    } else {
                        disableNotificationsAndUnregister()
                        showBackgroundLocationAlert = true
                    }
                }
            }, notDetermined: true)
        case .authorizedWhenInUse, .denied, .restricted:
            disableNotificationsAndUnregister()
            showBackgroundLocationAlert = true
        @unknown default:
            disableNotificationsAndUnregister()
            showBackgroundLocationAlert = true
        }
    }

    @MainActor
    private func requestMotionSharingPermissionIfNeeded() {
        switch PressureManager.motionAuthorizationStatus {
        case .authorized:
            return
        case .notDetermined:
            PressureManager.requestMotionPermission { granted in
                Task { @MainActor in
                    self.setMotionSharingEnabled(granted)
                    if !granted {
                        self.showMotionPermissionDeniedAlert = true
                    }
                }
            }
        case .denied, .restricted:
            setMotionSharingEnabled(false)
            showMotionPermissionDeniedAlert = true
        @unknown default:
            setMotionSharingEnabled(false)
        }
    }

    @MainActor
    private func ensureAutoZoomPermission() {
        switch SharedLocationUpdater.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return
        case .notDetermined:
            SharedLocationUpdater.requestAuthorization({ _, _ in
                Task { @MainActor in
                    switch SharedLocationUpdater.authorizationStatus {
                    case .authorizedAlways, .authorizedWhenInUse:
                        break
                    default:
                        settings.autoZoom = false
                        showAutoZoomPermissionAlert = true
                    }
                }
            }, notDetermined: true)
        case .denied, .restricted:
            settings.autoZoom = false
            showAutoZoomPermissionAlert = true
        @unknown default:
            settings.autoZoom = false
        }
    }

    @MainActor
    private func setMotionSharingEnabled(_ enabled: Bool) {
        isSyncingMotionPreference = true
        settings.motionSharingEnabled = enabled
        isSyncingMotionPreference = false
    }

    @MainActor
    private func disableNotificationsAndUnregister() {
        isSyncingPermission = true
        settings.notificationsEnabled = false
        isSyncingPermission = false
        SharedNotificationManager.unregisterFromBackend()
    }

    private func openFeedbackEmail() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let subject = "iOS App Feedback (\(version))"
        guard let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "mailto:support@meteocool.com?subject=\(encodedSubject)") else { return }
        UIApplication.shared.open(url)
    }
}

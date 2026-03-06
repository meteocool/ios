import CoreLocation
import CoreMotion
import SwiftUI
import UIKit
import UserNotifications

struct OnboardingView: View {
    @Environment(SettingsStore.self) private var settings
    let onContinue: () -> Void
    @State private var locationStatus: CLAuthorizationStatus = .notDetermined
    @State private var notificationsGranted: Bool = false
    @State private var motionGranted: Bool = false
    @State private var showNotificationPermissionDeniedAlert = false
    @State private var showBackgroundLocationAlert = false
    @State private var showMotionPermissionDeniedAlert = false

    private var locationGranted: Bool {
        switch locationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    Text(LocalizedStringKey("onboarding_title"))
                        .font(.title2.weight(.semibold))
                    Text(LocalizedStringKey("onboarding_welcome_text"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.top, 40)

                VStack(spacing: 12) {
                    permissionCard(
                        title: LocalizedStringKey("onboarding_location_title"),
                        description: LocalizedStringKey("onboarding_location_permission"),
                        actionTitle: locationGranted
                            ? LocalizedStringKey("onboarding_location_enabled")
                            : LocalizedStringKey("onboarding_location_enable"),
                        actionIcon: "location.fill",
                        enabled: locationGranted,
                        action: requestLocation
                    )

                    permissionCard(
                        title: LocalizedStringKey("Notifications"),
                        description: LocalizedStringKey("onboarding_notification_text"),
                        actionTitle: notificationsGranted
                            ? LocalizedStringKey("onboarding_notifications_enabled")
                            : LocalizedStringKey("Enable Notifications"),
                        actionIcon: "bell.badge.fill",
                        enabled: notificationsGranted,
                        action: requestNotifications
                    )

                    permissionCard(
                        title: LocalizedStringKey("onboarding_motion_title"),
                        description: LocalizedStringKey("onboarding_motion_description"),
                        actionTitle: motionGranted
                            ? LocalizedStringKey("onboarding_motion_enabled")
                            : LocalizedStringKey("onboarding_motion_enable"),
                        actionIcon: "barometer",
                        enabled: motionGranted,
                        action: requestMotion,
                        optional: true
                    )
                }

                Button {
                    onContinue()
                } label: {
                    Text(LocalizedStringKey("onboarding_continue"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .padding(.horizontal)
        }
        .background(.ultraThinMaterial)
        .task {
            await refreshStatuses()
        }
        .alert(LocalizedStringKey("notifications_disabled"), isPresented: $showNotificationPermissionDeniedAlert) {
            Button(LocalizedStringKey("Change in Settings")) {
                openSystemSettings()
            }
            Button(LocalizedStringKey("Dismiss"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("notification_permission_denied_message"))
        }
        .alert(LocalizedStringKey("location_permission_required"), isPresented: $showBackgroundLocationAlert) {
            Button(LocalizedStringKey("Change in Settings")) {
                openSystemSettings()
            }
            Button(LocalizedStringKey("Dismiss"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("enable_background_location_alert"))
        }
        .alert(LocalizedStringKey("motion_permission_required"), isPresented: $showMotionPermissionDeniedAlert) {
            Button(LocalizedStringKey("Change in Settings")) {
                openSystemSettings()
            }
            Button(LocalizedStringKey("Dismiss"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("motion_permission_denied_message"))
        }
    }

    @ViewBuilder
    private func permissionCard(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        actionTitle: LocalizedStringKey,
        actionIcon: String,
        enabled: Bool,
        action: @escaping () -> Void,
        optional: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                if optional {
                    Text(LocalizedStringKey("onboarding_optional_badge"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if enabled {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                action()
            } label: {
                Label(actionTitle, systemImage: actionIcon)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .disabled(enabled)
        }
        .padding()
        .liquidGlass(cornerRadius: 16)
    }

    @MainActor
    private func requestLocation() {
        SharedLocationUpdater.requestAuthorization({ _, _ in
            Task { @MainActor in
                refreshLocationStatus()
                await refreshNotificationStatus()
            }
        }, notDetermined: true)
    }

    @MainActor
    private func requestNotifications() {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let currentSettings = await center.notificationSettings()

            switch currentSettings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                settings.notificationsEnabled = true
                UIApplication.shared.registerForRemoteNotifications()
                ensureBackgroundLocationPermissionForNotifications()
            case .notDetermined:
                try? await SharedNotificationManager.register()
                if settings.notificationsEnabled {
                    ensureBackgroundLocationPermissionForNotifications()
                } else {
                    disableNotificationsAndUnregister()
                    showNotificationPermissionDeniedAlert = true
                }
            case .denied:
                disableNotificationsAndUnregister()
                showNotificationPermissionDeniedAlert = true
            @unknown default:
                disableNotificationsAndUnregister()
            }
        }
    }

    @MainActor
    private func requestMotion() {
        switch PressureManager.motionAuthorizationStatus {
        case .authorized:
            settings.motionSharingEnabled = true
            motionGranted = true
        case .notDetermined:
            PressureManager.requestMotionPermission { granted in
                Task { @MainActor in
                    settings.motionSharingEnabled = granted
                    motionGranted = granted
                    if !granted {
                        showMotionPermissionDeniedAlert = true
                    }
                }
            }
        case .denied, .restricted:
            settings.motionSharingEnabled = false
            motionGranted = false
            showMotionPermissionDeniedAlert = true
        @unknown default:
            settings.motionSharingEnabled = false
            motionGranted = false
        }
    }

    @MainActor
    private func refreshNotificationStatus() async {
        let notificationsAuthorized = await SharedNotificationManager.checkAuthorizationStatus()
        let hasBackgroundLocation = SharedLocationUpdater.authorizationStatus == .authorizedAlways

        if settings.notificationsEnabled && (!notificationsAuthorized || !hasBackgroundLocation) {
            disableNotificationsAndUnregister()
        }

        notificationsGranted = settings.notificationsEnabled && notificationsAuthorized && hasBackgroundLocation
    }

    @MainActor
    private func refreshLocationStatus() {
        locationStatus = SharedLocationUpdater.authorizationStatus
    }

    @MainActor
    private func refreshMotionStatus() {
        let status = PressureManager.motionAuthorizationStatus
        if settings.motionSharingEnabled && status != .authorized {
            settings.motionSharingEnabled = false
        }
        motionGranted = settings.motionSharingEnabled && status == .authorized
    }

    @MainActor
    private func refreshStatuses() async {
        refreshLocationStatus()
        refreshMotionStatus()
        await refreshNotificationStatus()
    }

    @MainActor
    private func ensureBackgroundLocationPermissionForNotifications() {
        switch SharedLocationUpdater.authorizationStatus {
        case .authorizedAlways:
            notificationsGranted = true
            SharedLocationUpdater.syncNotificationRegistrationNow()
        case .authorizedWhenInUse, .notDetermined:
            SharedLocationUpdater.requestAuthorization({ _, _ in
                Task { @MainActor in
                    refreshLocationStatus()
                    if SharedLocationUpdater.authorizationStatus == .authorizedAlways {
                        notificationsGranted = true
                        SharedLocationUpdater.syncNotificationRegistrationNow()
                    } else {
                        disableNotificationsAndUnregister()
                        showBackgroundLocationAlert = true
                    }
                }
            }, notDetermined: true)
        case .denied, .restricted:
            disableNotificationsAndUnregister()
            showBackgroundLocationAlert = true
        @unknown default:
            disableNotificationsAndUnregister()
            showBackgroundLocationAlert = true
        }
    }

    @MainActor
    private func disableNotificationsAndUnregister() {
        settings.notificationsEnabled = false
        notificationsGranted = false
        SharedNotificationManager.unregisterFromBackend()
    }

    @MainActor
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

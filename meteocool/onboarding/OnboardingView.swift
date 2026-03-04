import CoreLocation
import CoreMotion
import SwiftUI
import UserNotifications

struct OnboardingView: View {
    let onContinue: () -> Void
    @State private var locationStatus: CLAuthorizationStatus = .notDetermined
    @State private var notificationsGranted: Bool = false
    @State private var motionGranted: Bool = false

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
            await refreshNotificationStatus()
            refreshLocationStatus()
            refreshMotionStatus()
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

    private func requestLocation() {
        SharedLocationUpdater.requestAuthorization({ _, _ in
            Task { @MainActor in
                refreshLocationStatus()
            }
        }, notDetermined: true)
    }

    private func requestNotifications() {
        Task {
            try? await SharedNotificationManager.register()
            await refreshNotificationStatus()
        }
    }

    private func requestMotion() {
        PressureManager.requestMotionPermission { granted in
            Task { @MainActor in
                motionGranted = granted
            }
        }
    }

    @MainActor
    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            notificationsGranted = true
        default:
            notificationsGranted = false
        }
    }

    @MainActor
    private func refreshLocationStatus() {
        locationStatus = SharedLocationUpdater.authorizationStatus
    }

    @MainActor
    private func refreshMotionStatus() {
        let status = PressureManager.motionAuthorizationStatus
        motionGranted = status == .authorized
    }
}

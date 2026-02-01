import CoreLocation
import SwiftUI
import UserNotifications

struct OnboardingView: View {
    let onContinue: () -> Void
    @State private var locationStatus: CLAuthorizationStatus = .notDetermined
    @State private var notificationsGranted: Bool = false

    private var locationGranted: Bool {
        switch locationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 12) {
                Text(LocalizedStringKey("onboarding_title"))
                    .font(.title2.weight(.semibold))
                Text(LocalizedStringKey("onboarding_welcome_text"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

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

            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial)
        .task {
            await refreshNotificationStatus()
            await refreshLocationStatus()
        }
    }

    @ViewBuilder
    private func permissionCard(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        actionTitle: LocalizedStringKey,
        actionIcon: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if enabled {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)

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

    @MainActor
    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsGranted = settings.authorizationStatus == .authorized
    }

    @MainActor
    private func refreshLocationStatus() {
        locationStatus = SharedLocationUpdater.authorizationStatus
    }
}

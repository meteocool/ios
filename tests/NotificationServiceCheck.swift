import UserNotifications

@main
struct NotificationServiceCheck {
    static func main() async {
        for preview in [nil, "file:///tmp/not-an-attachment", "http://example.invalid/radar.png"] as [String?] {
            let content = UNMutableNotificationContent()
            content.title = "Rain soon"
            content.body = "Synthetic test alert"
            if let preview { content.userInfo["preview"] = preview }
            let request = UNNotificationRequest(identifier: "test", content: content, trigger: nil)
            let service = NotificationService()
            var deliveries = 0
            service.didReceive(request) { delivered in
                deliveries += 1
                precondition(delivered.title == content.title && delivered.body == content.body)
                precondition(delivered.attachments.isEmpty)
            }
            service.serviceExtensionTimeWillExpire()
            precondition(deliveries == 1, "Missing or unsafe previews must deliver the original alert exactly once")
        }
        print("Notification fallback and completion checks passed")
        if let preview = ProcessInfo.processInfo.environment["MC_PREVIEW_URL"] {
            let content = UNMutableNotificationContent()
            content.title = "Synthetic preview check"
            content.userInfo["preview"] = preview
            let service = NotificationService()
            let delivered = await withCheckedContinuation { continuation in
                service.didReceive(UNNotificationRequest(identifier: "preview", content: content, trigger: nil)) {
                    continuation.resume(returning: $0)
                }
            }
            precondition(delivered.attachments.count == 1, "HTTPS preview must become a notification attachment")
            print("Live HTTPS notification attachment check passed")
        }
    }
}

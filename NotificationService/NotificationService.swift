import UserNotifications

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?
    private let handlerLock = NSLock()
    private var didDeliverContent = false

    private func deliverOnce(_ content: UNNotificationContent) {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        guard !didDeliverContent else { return }
        didDeliverContent = true
        contentHandler?(content)
        contentHandler = nil
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        didDeliverContent = false
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        guard let bestAttemptContent = bestAttemptContent else {
            deliverOnce(request.content)
            return
        }
        guard let urlString = request.content.userInfo["preview"] as? String,
            let url = URL(string: urlString) else {
                deliverOnce(bestAttemptContent)
                return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data as NSData?,
               let attachment = UNNotificationAttachment.saveImageToDisk(fileIdentifier: "image.png", data: data, options: nil) {
                bestAttemptContent.attachments = [attachment]
            }
            self.deliverOnce(bestAttemptContent)
        }.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        if let bestAttemptContent = bestAttemptContent {
            deliverOnce(bestAttemptContent)
        }
    }
}

extension UNNotificationAttachment {
    static func saveImageToDisk(fileIdentifier: String, data: NSData, options: [NSObject: AnyObject]?) -> UNNotificationAttachment? {
        let fileManager = FileManager.default
        let folderName = ProcessInfo.processInfo.globallyUniqueString
        guard let folderURL = NSURL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(folderName, isDirectory: true) else {
            NSLog("Failed to create temp folder URL for notification attachment")
            return nil
        }

        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
            let fileURL = folderURL.appendingPathComponent(fileIdentifier)
            try data.write(to: fileURL, options: [])
            let attachment = try UNNotificationAttachment(identifier: fileIdentifier, url: fileURL, options: options)
            return attachment
        } catch let error {
            NSLog("Error \(error)")
        }

        return nil
    }
}

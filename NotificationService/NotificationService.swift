import UserNotifications

/// Attaches the radar image from a push's `preview` URL before the alert is shown.
/// The download callback and the expiration callback can run at the same time.
/// The lock guards the completion handler and the mutable content, so the alert
/// is delivered exactly once.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private var download: URLSessionDownloadTask?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        lock.withLock {
            self.handler = contentHandler
            self.content = content
        }
        guard let preview = content.userInfo["preview"] as? String,
              let url = URL(string: preview), url.scheme == "https", url.host != nil else {
            finish()
            return
        }
        var request = URLRequest(url: url)
        // The preview is rendered on request, and a cold render takes 13 to 20 s.
        // The system gives the extension about 30 s; if that runs out first,
        // `serviceExtensionTimeWillExpire` delivers the alert without the image.
        request.timeoutInterval = 28
        let task = URLSession.shared.downloadTask(with: request) { [weak self] file, response, error in
            var attachment: UNNotificationAttachment?
            if error == nil, let file, let response = response as? HTTPURLResponse,
               response.statusCode == 200, response.url?.scheme == "https",
               response.mimeType == "image/png",
               let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > 0, size <= 10 * 1024 * 1024 {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let image = folder.appendingPathComponent("radar.png")
                    try FileManager.default.moveItem(at: file, to: image)
                    attachment = try UNNotificationAttachment(identifier: "radar", url: image)
                } catch {
                    // Deliver the text alert without the image if the preview fails.
                    NSLog("Notification preview unavailable")
                }
            }
            self?.finish(attachment: attachment)
        }
        let shouldStart = lock.withLock {
            guard handler != nil else { return false }
            download = task
            return true
        }
        if shouldStart { task.resume() } else { task.cancel() }
    }

    override func serviceExtensionTimeWillExpire() { finish() }

    private func finish(attachment: UNNotificationAttachment? = nil) {
        lock.lock()
        guard let handler, let content else {
            lock.unlock()
            return
        }
        if let attachment { content.attachments = [attachment] }
        let task = download
        self.handler = nil
        self.content = nil
        download = nil
        lock.unlock()
        task?.cancel()
        handler(content)
    }
}

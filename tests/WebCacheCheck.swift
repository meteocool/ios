import UIKit

// Only UIKit's background-task scheduler is substituted. WebCache's file
// enumeration, asynchronous work and completion paths run unchanged.
@MainActor final class UIApplication {
    static let shared = UIApplication()
    var expires: (@MainActor () -> Void)?
    var ended: [UIBackgroundTaskIdentifier] = []
    var next = UIBackgroundTaskIdentifier(rawValue: 1)

    func beginBackgroundTask(withName: String?, expirationHandler: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        expires = expirationHandler
        return next
    }

    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) { ended.append(id) }
}

@main struct WebCacheCheck {
    @MainActor static func main() async throws {
        precondition(Bundle.main.bundleIdentifier != nil, "Run this check from its app bundle")
        let application = UIApplication.shared
        await WebCache.trimIfNeeded()?.value
        precondition(application.ended == [application.next], "Normal completion must release its background task")

        application.ended = []
        let expiring = WebCache.trimIfNeeded()
        application.expires?()
        await expiring?.value
        precondition(application.ended == [application.next], "Expiration followed by completion must release the task only once")

        application.ended = []
        application.next = .invalid
        await WebCache.trimIfNeeded()?.value
        precondition(application.ended.isEmpty, "An invalid background task must never be ended")
        print("Web cache background-task lifecycle checks passed")
    }
}

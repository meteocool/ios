import UIKit
import WebKit

/// Keeps the map's web cache from growing without bound (issue #141).
///
/// Every radar frame has its own tile URLs, so WebKit's HTTP cache fills with
/// frames nobody will request again. WebKit sizes that cache from free disk
/// space, and iOS only purges `Library/Caches` under storage pressure, so it
/// can reach several GB.
/// core's service worker bounds its own tile caches, but a `WKWebView` in an
/// app without `WKAppBoundDomains` does not run service workers.
///
/// WebKit can only remove cached data modified after a date, not before, so
/// the whole cache goes once it passes `limit`. The next launch fetches the
/// basemap again; radar frames are stale after a few hours anyway.
enum WebCache {
    static let limit: Int64 = 100 * 1024 * 1024

    /// The HTTP cache and CacheStorage, both under `Library/Caches/<bundle id>/WebKit`.
    /// Local storage is not touched.
    private static let dataTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeFetchCache,
    ]

    private static var directory: URL? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("WebKit", isDirectory: true)
    }

    /// Measures the cache off the main thread and clears it when it is over `limit`.
    @MainActor static func trimIfNeeded() {
        guard let directory else { return }
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "WebCache.trim") {
            UIApplication.shared.endBackgroundTask(task)
        }
        let id = task
        Task { @MainActor in
            let size = await Task.detached(priority: .utility) { allocatedSize(of: directory) }.value
            if size > limit {
                NSLog("WebCache: \(size / 1024 / 1024) MB is over the limit, clearing")
                await WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast)
            }
            UIApplication.shared.endBackgroundTask(id)
        }
    }

    private static func allocatedSize(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

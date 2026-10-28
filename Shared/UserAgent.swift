import Foundation

/// What the app tells the servers it is: `meteocool/4.1.0 (16; iOS 27.0)`,
/// the version people see, the build, and the system it runs on.
///
/// CFNetwork's own user agent names only the build (`meteocool/16`) and
/// Darwin's version, and the web view's freezes the system at iOS 18, so
/// without this the backend's dashboards cannot tell which release or which
/// iOS anyone runs. The app and its extensions share the one version.
enum UserAgent {
    static let value: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return "meteocool/\(version) (\(build); iOS \(system.majorVersion).\(system.minorVersion))"
    }()
}

extension URLSession {
    /// `URLSession.shared`, but sending `UserAgent.value`.
    static let meteocool: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": UserAgent.value]
        return URLSession(configuration: configuration)
    }()
}

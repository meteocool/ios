import Foundation

/// Which meteocool deployment the app talks to.
///
/// The web map and the native API must always use the same deployment:
/// - The staging frontend is built against the staging backend's contract
///   (`--mode staging` in meteocool/core).
/// - A push registration posted to the wrong deployment never produces a notification.
///
/// Both URLs are defined here. Call sites read `MeteocoolEnvironment.current`
/// and never hardcode a host.
enum MeteocoolEnvironment: CaseIterable {
    /// The deployment App Store builds talk to.
    case production
    /// Staging: the staging API, and core's
    /// `--mode staging` build.
    case staging
    /// Demo: the staging code replaying a
    /// recorded storm as if it were happening now, and core's `--mode demo`
    /// build.
    case demo

    /// Demo when Settings' "Demo Mode" is on, otherwise staging.
    /// "Experimental Features" does not change the result.
    /// Never production: production has not moved to the v4 backend this build
    /// is written against.
    ///
    /// Read once per process. Changing the switch therefore cannot put the web
    /// map and the native API on different deployments before the restart that
    /// the settings screen asks for.
    /// Exception: `leaveDemo()` changes it at runtime, and its caller switches
    /// both at once.
    // Written only on the main thread, by `leaveDemo()`.
    nonisolated(unsafe) private(set) static var current: MeteocoolEnvironment =
        UserDefaults(suiteName: "group.org.frcy.app.meteocool")?.bool(forKey: "demoMode") == true ? .demo : .staging

    /// Switches a demo session to staging without a restart.
    /// Used by "Disable Demo Mode" in the launch notice.
    /// The caller reloads the map and calls `refreshAuthorization`, which moves
    /// a push registration made on demo: it removes it from demo's API, then
    /// registers with staging's.
    /// No app dependencies here: the check scripts compile this file alone.
    @MainActor static func leaveDemo() {
        UserDefaults(suiteName: "group.org.frcy.app.meteocool")?.set(false, forKey: "demoMode")
        current = .staging
    }

    /// Base URL for the unversioned mobile API (`post_location`,
    /// `clear_notification`, `unregister`).
    ///
    /// On staging these are served by the v4 backend's legacy compatibility
    /// router, which accepts the same payloads as the old Flask service.
    var apiBaseURL: URL {
        switch self {
        case .production:
            return URL(string: "https://api.ng.meteocool.com/")!
        case .staging:
            return URL(string: "https://api-next.meteocool.com/")!
        case .demo:
            return URL(string: "https://api-demo.meteocool.com/")!
        }
    }

    /// The API URL a stored registration origin is known by now, or nil if it
    /// is not one of this app's APIs.
    /// Staging's API was renamed from `staging.meteocool.com` to
    /// `api-next.meteocool.com`. Both names reach the same API, so a
    /// registration stored under the old name belongs to staging.
    static func apiBaseURL(forStored stored: URL) -> URL? {
        if stored == URL(string: "https://staging.meteocool.com/") { return staging.apiBaseURL }
        return allCases.map(\.apiBaseURL).first { $0 == stored }
    }

    /// Web hosts. Staging and demo use the custom domains set in core/wrangler.jsonc.
    private var webHost: String {
        switch self {
        case .production:
            return "https://meteocool.com"
        case .staging:
            return "https://next.meteocool.com"
        case .demo:
            return "https://demo.meteocool.com"
        }
    }

    /// The page the map `WKWebView` loads.
    ///
    /// `ios.html` is a named entry point of core's multi-page Vite build.
    /// The Worker is configured with `html_handling: "none"`, so the `.html`
    /// URL resolves directly and is not redirected to `/ios`.
    var webURL: URL {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["MC_TEST_MAP"] == "1", let local = NetworkHelper.simulatorTestAPI {
            return local.appendingPathComponent("ios.html")
        }
        #endif
        return page()
    }

    /// The map page for CarPlay, without controls.
    ///
    /// `toolbar=no` is a URL setting read by core (`src/App.svelte`).
    /// It removes the bottom toolbar, the forecast strip and their padding.
    /// The result is the live radar with nothing to tap.
    /// App builds already hide the logo and the layer switcher.
    var carPlayURL: URL {
        page(query: ["toolbar": "no"])
    }

    private func page(query: [String: String] = [:]) -> URL {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var components = URLComponents(string: "\(webHost)/ios.html")!
        components.queryItems = [URLQueryItem(name: "version", value: version)]
            + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }
}

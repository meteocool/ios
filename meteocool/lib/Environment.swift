import Foundation

/// Which meteocool deployment the app talks to.
///
/// The web map and the native API must always use the same deployment:
/// - Each core build is built against one backend's contract
///   (`--mode staging` or `--mode demo` in meteocool/core).
/// - A push registration posted to the wrong deployment never produces a notification.
///
/// Both URLs are defined here. Call sites read `MeteocoolEnvironment.current`
/// and never hardcode a host.
enum MeteocoolEnvironment: CaseIterable {
    /// The default: app.meteocool.com, for the map and the API alike.
    /// It is a custom domain of whichever core Worker the app should use, and
    /// that Worker forwards the API calls to its own backend (core's
    /// `worker/api.ts`). Moving the domain to another Worker moves the app,
    /// map and registrations together, without an app release.
    case app
    /// The staging cluster, with "Experimental Features" on: ng's `v4` in the
    /// staging namespace, and core's `--mode staging` build.
    case staging
    /// The demo namespace on the same cluster, with "Demo Mode" on: the staging
    /// code replaying a recorded storm as if it were happening now, and core's
    /// `--mode demo` build.
    case demo

    /// Demo when Settings' "Demo Mode" is on, staging when "Experimental
    /// Features" is on, otherwise app. Settings keeps the two switches exclusive.
    ///
    /// Read once per process. Changing a switch therefore cannot put the web
    /// map and the native API on different deployments before the restart that
    /// the settings screen asks for.
    /// Exception: `leaveDemo()` changes it at runtime, and its caller switches
    /// both at once.
    // Written only on the main thread, by `leaveDemo()`.
    nonisolated(unsafe) private(set) static var current: MeteocoolEnvironment = selected()

    private static func selected() -> MeteocoolEnvironment {
        let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
        if defaults?.bool(forKey: "demoMode") == true { return .demo }
        if defaults?.bool(forKey: "experimentalFeatures") == true { return .staging }
        return .app
    }

    /// Switches a demo session to app, or to staging with "Experimental
    /// Features" on, without a restart.
    /// Used by "Disable Demo Mode" in the launch notice.
    /// The caller reloads the map and calls `refreshAuthorization`, which moves
    /// a push registration made on demo: it removes it from demo's API, then
    /// registers with the new one.
    /// No app dependencies here: the check scripts compile this file alone.
    @MainActor static func leaveDemo() {
        UserDefaults(suiteName: "group.org.frcy.app.meteocool")?.set(false, forKey: "demoMode")
        current = selected()
    }

    /// Base URL for the unversioned mobile API (`post_location`,
    /// `clear_notification`, `unregister`).
    ///
    /// These are served by the v4 backend's legacy compatibility router, which
    /// accepts the same payloads as the old Flask service.
    var apiBaseURL: URL {
        switch self {
        case .app:
            return URL(string: "https://app.meteocool.com/")!
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

    /// Web hosts: custom domains of core's Workers, set in core/wrangler.jsonc.
    private var webHost: String {
        switch self {
        case .app:
            return "https://app.meteocool.com"
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

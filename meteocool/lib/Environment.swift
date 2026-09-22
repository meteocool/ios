import Foundation

/// Which meteocool deployment the app talks to.
///
/// The web map and the native API have to move together. The staging frontend
/// is built against the staging backend's contract (`--mode staging` in
/// meteocool/core), and a push registration posted to the wrong deployment
/// simply never produces a notification — so both URLs live here and every
/// call site asks `MeteocoolEnvironment.current` rather than hardcoding a host.
///
/// Before this existed the "Experimental Features" switch moved only the web
/// view: native API calls kept going to production, so a staging session
/// registered its push token with the wrong cluster.
enum MeteocoolEnvironment {
    /// The deployment App Store builds talk to.
    case production
    /// The staging cluster, deployed from core's `develop` branch and ng's
    /// staging namespace.
    case staging

    /// Selected by the "Experimental Features" setting. Changing it needs a
    /// restart, which is what the settings screen already tells the user, so
    /// the selection is fixed for this process. Native and web requests must
    /// not split across deployments before that restart.
    static let current: MeteocoolEnvironment = {
        let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
        return defaults?.bool(forKey: "experimentalFeatures") == true ? .staging : .production
    }()

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
            return URL(string: "https://staging.meteocool.com/")!
        }
    }

    /// Web hosts; staging follows core/wrangler.jsonc's custom domain.
    private var webHost: String {
        switch self {
        case .production:
            return "https://meteocool.com"
        case .staging:
            return "https://web.staging.meteocool.com"
        }
    }

    /// The page the map `WKWebView` loads.
    ///
    /// `ios.html` is a named entry point of core's multi-page Vite build, and
    /// the Worker is configured with `html_handling: "none"` so the `.html`
    /// suffix keeps resolving instead of redirecting to `/ios`.
    var webURL: URL {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["MC_TEST_MAP"] == "1", let local = NetworkHelper.simulatorTestAPI {
            return local.appendingPathComponent("ios.html")
        }
        #endif
        return page()
    }

    /// The same map, stripped for the car.
    ///
    /// `toolbar=no` is a URL-sourced setting in core (`src/App.svelte`): it
    /// drops the bottom toolbar, the forecast strip and the padding they
    /// reserve, which leaves the live radar and nothing to tap. The logo and
    /// the layer switcher are already off for app builds.
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

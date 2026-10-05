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
enum MeteocoolEnvironment: String, CaseIterable {
    /// The default, "Production" in Settings: app.meteocool.com, for the map
    /// and the API alike.
    /// It is a custom domain of whichever core Worker the app should use, and
    /// that Worker forwards the API calls to its own backend (core's
    /// `worker/api.ts`). Moving the domain to another Worker moves the app,
    /// map and registrations together, without an app release.
    case app
    /// Staging, "Experimental Features" in Settings: the staging API
    ///, and core's `--mode staging` build.
    case staging
    /// Demo, "Demo" in Settings: the staging
    /// code replaying a recorded storm as if it were happening now, and core's
    /// `--mode demo` build.
    case demo

    /// Posted on the main thread after `select(_:)` changes `current`.
    /// The map pages reload and the push registration moves to the new API.
    static let didChange = Notification.Name("MeteocoolEnvironmentChanged")

    /// The deployment chosen under Mode in Settings, stored under `environment`.
    ///
    /// Only `select(_:)` changes it, and it posts `didChange` so the web map
    /// and the native API move together. Nothing reads the stored value
    /// directly: a reader that cached it could end up on another deployment
    /// than the map.
    // Written only on the main thread, by `select(_:)`.
    nonisolated(unsafe) private(set) static var current: MeteocoolEnvironment = stored(in: UserDefaults(suiteName: "group.org.frcy.app.meteocool"))

    /// The stored deployment, migrating the two switches that preceded Mode.
    ///
    /// Up to 2.x the deployment was two switches, "Experimental Features" and
    /// "Demo Mode". Demo carries over, so the launch notice keeps reminding
    /// the user. Experimental Features does not: everyone who had it on goes
    /// back to production once, and picks it again under Mode if they want it.
    /// No app dependencies here: the check scripts compile this file alone.
    static func stored(in defaults: UserDefaults?) -> MeteocoolEnvironment {
        if let value = defaults?.string(forKey: "environment"), let environment = MeteocoolEnvironment(rawValue: value) {
            return environment
        }
        let environment: MeteocoolEnvironment = defaults?.bool(forKey: "demoMode") == true ? .demo : .app
        defaults?.set(environment.rawValue, forKey: "environment")
        defaults?.removeObject(forKey: "demoMode")
        defaults?.removeObject(forKey: "experimentalFeatures")
        return environment
    }

    /// Switches the whole app to `environment`, without a restart.
    /// The observers of `didChange` reload the map pages and move a push
    /// registration: it is removed from the old API, then made on the new one.
    @MainActor static func select(_ environment: MeteocoolEnvironment) {
        guard environment != current else { return }
        UserDefaults(suiteName: "group.org.frcy.app.meteocool")?.set(environment.rawValue, forKey: "environment")
        current = environment
        NotificationCenter.default.post(name: didChange, object: nil)
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

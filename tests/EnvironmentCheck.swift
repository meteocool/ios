import Foundation

@main
enum EnvironmentCheck {
    static func main() {
        let suite = "meteocool.environment-check.\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        func migrate(experimental: Bool?, demo: Bool?) -> MeteocoolEnvironment {
            defaults.removePersistentDomain(forName: suite)
            if let experimental { defaults.set(experimental, forKey: "experimentalFeatures") }
            if let demo { defaults.set(demo, forKey: "demoMode") }
            return MeteocoolEnvironment.stored(in: defaults)
        }

        precondition(migrate(experimental: nil, demo: nil) == .app, "A new install starts on production")
        precondition(migrate(experimental: true, demo: false) == .app, "Experimental Features resets to production")
        precondition(defaults.object(forKey: "experimentalFeatures") == nil, "The old switches are removed")
        precondition(migrate(experimental: false, demo: true) == .demo, "Demo Mode carries over")
        precondition(defaults.string(forKey: "environment") == "demo")

        defaults.set("staging", forKey: "environment")
        defaults.set(true, forKey: "demoMode")
        precondition(MeteocoolEnvironment.stored(in: defaults) == .staging, "A stored mode wins over leftover switches")
        defaults.set("bogus", forKey: "environment")
        defaults.removeObject(forKey: "demoMode")
        precondition(MeteocoolEnvironment.stored(in: defaults) == .app, "An unknown mode falls back to production")
        print("Environment selection and migration checks passed")
    }
}

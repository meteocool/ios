//
//  MapRecovery.swift
//  meteocool
//
//  Reloads the map page until it comes up, and again whenever it dies.
//

import Network
import UIKit
import WebKit

/// Keeps the map page alive, so that no state of the web view needs the user
/// to do anything.
///
/// The page counts as up once it posts `requestSettings`. Until then, and
/// after any of these, the page is loaded again:
/// - the navigation fails, or the page does not report in (`loadStarted`);
/// - the web content process dies, usually from memory pressure;
/// - a map canvas loses its WebGL context and does not get it back
///   (`graphicsWatch`);
/// - the page no longer answers when the app returns to the foreground.
///
/// Retries back off from one second to `maxDelay`, and happen at once when
/// the network comes back or the app returns to the foreground.
///
/// While the page runs, the view on screen (`window.shareLink()`, the link
/// the share sheet offers) is noted every `viewInterval`. The first reload
/// after a page that ran opens that view again, so a crash in the 3D map
/// comes back to the same storm rather than the radar. Should the page die
/// again before `stableAfter`, the view may be what kills it, and the next
/// reload is the plain map.
@MainActor
final class MapRecovery {
    enum Failure: String {
        case navigation, timeout, crash, graphics, unresponsive
    }

    /// The page reports in within this time, or once loading stops after it.
    static let readyTimeout: TimeInterval = 20
    /// Longest wait for a page that is still loading on a slow connection.
    static let maxLoadTime: TimeInterval = 45
    /// Longest wait between two retries.
    static let maxDelay: TimeInterval = 15
    /// A page up this long resets the backoff when it fails, so a single
    /// crash reloads at once while a page that keeps crashing backs off.
    static let stableAfter: TimeInterval = 60
    /// How often the view on screen is noted.
    static let viewInterval: TimeInterval = 3

    /// Seconds to wait before retry number `failures`: 1, 2, 4, 8, then `maxDelay`.
    static func delay(afterFailures failures: Int) -> TimeInterval {
        min(pow(2, Double(max(failures, 1) - 1)), maxDelay)
    }

    private weak var webView: WKWebView?
    private let reload: (_ view: String?) -> Void
    private let wentDown: () -> Void
    private let showStatus: (Bool) -> Void

    private var failures = 0
    /// When the page last reported in. Nil while loading or failed.
    private var readySince: Date?
    /// Armed while a load is in progress.
    private var watchdog: Task<Void, Never>?
    /// Armed while waiting to retry.
    private var retry: Task<Void, Never>?
    private var retryInForeground = false
    /// Notes the view while the page runs.
    private var viewWatch: Task<Void, Never>?
    /// The search of the link to the view on screen, last time it was asked.
    private var lastView: String?
    private let pathMonitor = NWPathMonitor()
    private var online = true

    /// - Parameters:
    ///   - reload: loads the map page again, opening `view` (a link's search)
    ///     if there is one; it calls `loadStarted`.
    ///   - wentDown: the page stopped working, whatever the cause.
    ///   - showStatus: shows or hides the "trying again" status.
    init(webView: WKWebView, reload: @escaping (_ view: String?) -> Void, wentDown: @escaping () -> Void, showStatus: @escaping (Bool) -> Void) {
        self.webView = webView
        self.reload = reload
        self.wentDown = wentDown
        self.showStatus = showStatus
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "org.frcy.meteocool.map-recovery"))
    }

    /// A load of the map page started, by `reload` or by the page itself.
    func loadStarted() {
        retry?.cancel()
        retry = nil
        retryInForeground = false
        forgetOldFailures()
        readySince = nil
        stopWatchingView()
        watchdog?.cancel()
        // Counts ticks rather than reading the clock, so time spent suspended
        // in the background does not count against the page.
        watchdog = Task { [weak self] in
            var waited: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                waited += 5
                let loading = self.webView?.isLoading ?? false
                if waited >= Self.maxLoadTime || (waited >= Self.readyTimeout && !loading) {
                    self.failed(.timeout)
                    return
                }
            }
        }
    }

    /// The page reported in.
    func loadSucceeded() {
        watchdog?.cancel()
        watchdog = nil
        readySince = Date()
        showStatus(false)
        watchView()
    }

    /// The page failed to load, or died after loading. Ignored while already
    /// waiting to retry, so two reports of one failure count once.
    func failed(_ failure: Failure) {
        guard watchdog != nil || readySince != nil else { return }
        watchdog?.cancel()
        watchdog = nil
        forgetOldFailures()
        readySince = nil
        viewWatch?.cancel()
        viewWatch = nil
        failures += 1
        NSLog("Map failed (%@), attempt %d", failure.rawValue, failures)
        wentDown()
        // The first retry is quick and usually works: say nothing until it fails too.
        if failures > 1 { showStatus(true) }

        // A page reloaded in the background can be killed again before
        // anyone sees it. Retry when the app returns.
        if UIApplication.shared.applicationState == .background {
            retryInForeground = true
            return
        }
        let delay = Self.delay(afterFailures: failures)
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.retryNow()
        }
    }

    /// Retries a failed page now instead of after the backoff. A load in
    /// progress goes on. Without `restoringView`, the page comes back
    /// with its own view instead of the one it died with.
    func hurry(restoringView: Bool = true) {
        if !restoringView { lastView = nil }
        if retryInForeground || retry != nil { retryNow() }
    }

    private func retryNow() {
        retry?.cancel()
        retry = nil
        retryInForeground = false
        reload(failures == 1 ? lastView : nil)
    }

    /// Asks the page for its view every `viewInterval` while it runs. A page
    /// from before sharing has no `window.shareLink` and leaves nothing to
    /// open again.
    private func watchView() {
        viewWatch?.cancel()
        viewWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let webView = self?.webView else { return }
                let json = try? await webView.evaluateJavaScript("JSON.stringify(window.shareLink ? window.shareLink() : null)") as? String
                guard !Task.isCancelled, let self else { return }
                if let json, let share = MapShare(json: json, mapHost: webView.url?.host) {
                    self.lastView = share.viewSearch
                }
                try? await Task.sleep(for: .seconds(Self.viewInterval))
            }
        }
    }

    /// A new page, other than a retry, starts from its own view.
    private func stopWatchingView() {
        viewWatch?.cancel()
        viewWatch = nil
        lastView = nil
    }

    /// The app returned to the foreground. Retries a failed page at once, and
    /// asks a loaded one whether it still runs: a page can die in the
    /// background without the termination callback, or hang.
    func becameActive() {
        hurry()
        guard let asked = readySince, let webView else { return }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.unresponsive(since: asked)
        }
        webView.evaluateJavaScript("typeof window.settings?.injectSettings === 'function'") { [weak self] result, _ in
            timeout.cancel()
            if result as? Bool != true { self?.unresponsive(since: asked) }
        }
    }

    /// Fails the page that was asked, not one loaded since.
    private func unresponsive(since asked: Date) {
        if readySince == asked { failed(.unresponsive) }
    }

    private func forgetOldFailures() {
        if let readySince, Date().timeIntervalSince(readySince) > Self.stableAfter { failures = 0 }
    }

    private func networkChanged(online: Bool) {
        defer { self.online = online }
        guard online, !self.online, retry != nil else { return }
        retryNow()
    }

    /// Reports a map canvas whose WebGL context stays lost, as
    /// `mapGraphicsLost` on `scriptHandler`.
    ///
    /// OpenLayers and MapLibre ask for a lost context back and redraw when it
    /// returns, which covers a GPU process restart. A context WebKit takes
    /// away for good (too many contexts, a GPU fault) leaves a blank or
    /// frozen map that never recovers, and only a reload helps.
    ///
    /// Only canvases inside `#map`, the map on screen, count: the layer
    /// switcher's previews and detached maps can lose theirs harmlessly. A
    /// hidden page reports nothing, and a page shown again gets
    /// `graceSeconds` for its contexts to come back first.
    static var graphicsWatch: WKUserScript {
        let graceSeconds = 5
        let source = """
        (() => {
          const lost = new Set();
          let visibleSince = document.visibilityState === "visible" ? Date.now() : Infinity;
          let timer = null;
          document.addEventListener("visibilitychange", () => {
            visibleSince = document.visibilityState === "visible" ? Date.now() : Infinity;
          });
          const check = () => {
            timer = null;
            if (!lost.size) return;
            const shown = Date.now() - visibleSince >= \(graceSeconds * 1000);
            if (shown && [...lost].some((canvas) => canvas.isConnected && canvas.closest("#map"))) {
              lost.clear();
              window.webkit?.messageHandlers?.scriptHandler?.postMessage("mapGraphicsLost");
              return;
            }
            timer = setTimeout(check, \(graceSeconds * 1000));
          };
          document.addEventListener("webglcontextlost", (event) => {
            if (!(event.target instanceof HTMLCanvasElement)) return;
            lost.add(event.target);
            if (timer === null) timer = setTimeout(check, \(graceSeconds * 1000));
          }, true);
          document.addEventListener("webglcontextrestored", (event) => lost.delete(event.target), true);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}

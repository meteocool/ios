//
//  GeolocationBridge.swift
//  meteocool
//
//  Answers the web map's geolocation calls from CoreLocation.
//

import CoreLocation
import WebKit

/// Replaces `navigator.geolocation` in the web map with a shim fed by the app's CoreLocation fixes.
///
/// Why: a `navigator.geolocation` call inside a `WKWebView` shows WebKit's own
/// per-origin permission alert ("Allow … to use your location?"). The app
/// already holds location permission, so that is a second prompt.
/// The app sends the map its position natively (`window.lm.updateLocation`)
/// for the same reason.
///
/// A check in the frontend covers only the call sites the frontend knows about.
/// This user script runs at document start and replaces `navigator.geolocation`
/// for every caller, including libraries inside the page. WebKit's geolocation
/// code is never called, so its prompt cannot appear.
///
/// The shim implements `getCurrentPosition`, `watchPosition` and `clearWatch`.
/// Positions arrive through `deliver(_:to:)`. `ViewController.notify(location:)`
/// calls it for every fix, so watchers update while native updates run.
@MainActor
enum GeolocationBridge {
    /// The message handler the shim posts to. Registered by `ViewController`.
    static let handlerName = "geolocationHandler"

    /// Posted when the page wants a position and the shim has none cached.
    static let requestAction = "requestPosition"

    /// W3C `GeolocationPositionError` codes.
    enum ErrorCode: Int {
        case permissionDenied = 1
        case positionUnavailable = 2
    }

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// Hands a fix to the shim, which resolves pending `getCurrentPosition`
    /// calls and fires every active watcher.
    static func deliver(_ location: CLLocation, to webView: WKWebView) {
        // CoreLocation reports "unknown" as a negative value.
        // The Geolocation API reports it as `null`.
        let position: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": max(location.horizontalAccuracy, 0),
            "altitude": location.verticalAccuracy >= 0 ? location.altitude : NSNull(),
            "altitudeAccuracy": location.verticalAccuracy >= 0 ? location.verticalAccuracy : NSNull(),
            "heading": location.course >= 0 ? location.course : NSNull(),
            "speed": location.speed >= 0 ? location.speed : NSNull(),
            "timestamp": location.timestamp.timeIntervalSince1970 * 1000,
        ]
        guard let json = encode(position) else { return }
        webView.evaluateJavaScript("window.__mcGeo && window.__mcGeo.push(\(json));")
    }

    /// Fails pending requests and active watchers.
    /// A later request checks native permission again, so returning from
    /// Settings does not need a page reload.
    static func fail(_ code: ErrorCode, message: String, to webView: WKWebView) {
        guard let json = encode(["code": code.rawValue, "message": message]) else { return }
        webView.evaluateJavaScript("window.__mcGeo && window.__mcGeo.fail(\(json));")
    }

    private static func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Runs before the trusted main page's own scripts.
    ///
    /// Raw string literal, because the JS contains many `\(` sequences.
    /// An ordinary Swift string would treat them as interpolation.
    private static let source = #"""
    (function () {
      var handler = window.webkit
        && window.webkit.messageHandlers
        && window.webkit.messageHandlers.geolocationHandler;
      if (!handler) return;

      var PERMISSION_DENIED = 1;
      var POSITION_UNAVAILABLE = 2;
      var TIMEOUT = 3;

      var nextId = 1;
      var pending = [];        // one-shot getCurrentPosition calls
      var watchers = {};       // id -> { success, error }
      var last = null;         // the most recent fix the host delivered

      function position(fix) {
        return {
          coords: {
            latitude: fix.latitude,
            longitude: fix.longitude,
            accuracy: fix.accuracy,
            altitude: fix.altitude,
            altitudeAccuracy: fix.altitudeAccuracy,
            heading: fix.heading,
            speed: fix.speed,
          },
          timestamp: fix.timestamp,
        };
      }

      function error(code, message) {
        return {
          code: code,
          message: message,
          PERMISSION_DENIED: PERMISSION_DENIED,
          POSITION_UNAVAILABLE: POSITION_UNAVAILABLE,
          TIMEOUT: TIMEOUT,
        };
      }

      /* Callbacks are the page's code: one throwing must not take the rest of
         the queue with it. */
      function invoke(callback, argument) {
        if (typeof callback !== "function") return;
        try {
          callback(argument);
        } catch (e) {
          console.error("geolocation callback failed", e);
        }
      }

      function settle(request, fix) {
        if (request.timer) clearTimeout(request.timer);
        invoke(request.success, position(fix));
      }

      window.__mcGeo = {
        /* Called by the host for every fix it receives. */
        push: function (fix) {
          last = fix;
          var waiting = pending;
          pending = [];
          waiting.forEach(function (request) { settle(request, fix); });
          Object.keys(watchers).forEach(function (id) {
            if (watchers[id]) settle(watchers[id], fix);
          });
        },

        /* Called by the host when it cannot produce one. */
        fail: function (reason) {
          if (reason.code === PERMISSION_DENIED) last = null;
          var waiting = pending;
          pending = [];
          waiting.forEach(function (request) {
            if (request.timer) clearTimeout(request.timer);
            invoke(request.error, error(reason.code, reason.message));
          });
          Object.keys(watchers).forEach(function (id) {
            var watcher = watchers[id];
            if (!watcher) return;
            if (watcher.timer) clearTimeout(watcher.timer);
            if (reason.code === PERMISSION_DENIED) delete watchers[id];
            invoke(watcher.error, error(reason.code, reason.message));
          });
        },
      };

      function ask(success, failure, options, watchId) {
        var request = { success: success, error: failure, timer: null };
        if (watchId) watchers[watchId] = request;
        var maximumAge = options && typeof options.maximumAge === "number" ? Math.max(0, options.maximumAge) : 0;
        if (last && maximumAge > 0 && Date.now() - last.timestamp <= maximumAge) {
          var cached = last;
          request.timer = setTimeout(function () { settle(request, cached); }, 0);
          return;
        }

        if (options && typeof options.timeout === "number" && options.timeout >= 0 && isFinite(options.timeout)) {
          request.timer = setTimeout(function () {
            var index = pending.indexOf(request);
            if (index !== -1) pending.splice(index, 1);
            invoke(failure, error(TIMEOUT, "Timed out waiting for the app's location"));
          }, options.timeout);
        }
        if (!watchId) pending.push(request);
        handler.postMessage("requestPosition");
      }

      var geolocation = {
        getCurrentPosition: function (success, failure, options) {
          ask(success, failure, options);
        },

        watchPosition: function (success, failure, options) {
          var id = nextId++;
          /* A watcher is expected to report the current position too, and the
             host keeps sending fixes for as long as its updates run. */
          ask(success, failure, options, id);
          return id;
        },

        clearWatch: function (id) {
          if (watchers[id] && watchers[id].timer) clearTimeout(watchers[id].timer);
          delete watchers[id];
        },
      };

      /* `geolocation` is an accessor on Navigator.prototype, so shadowing it on
         the instance is enough -- and if a future WebKit makes that fail, the
         prototype accessor itself is replaced instead. */
      try {
        Object.defineProperty(navigator, "geolocation", {
          value: geolocation,
          configurable: true,
          enumerable: true,
        });
      } catch (e) {
        Object.defineProperty(Navigator.prototype, "geolocation", {
          get: function () { return geolocation; },
          configurable: true,
        });
      }
    })();
    """#
}

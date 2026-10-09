import UIKit
import WebKit

/// A Mac trackpad's pinch and rotation, handed to the map page as gestures it
/// already understands.
///
/// On a Mac the app runs as its iPad build ("Designed for iPad"), and WebKit
/// passes a trackpad's two-finger scroll to the page as `wheel` events, but not
/// a pinch or a rotation: those reach only UIKit's gesture recognizers, so the
/// map neither zoomed nor turned.
///
/// A pinch becomes what Chrome sends for one, `wheel` events with `ctrlKey` set
/// at the pointer, which OpenLayers (the 2D map) and MapLibre (the 3D map) both
/// read as trackpad zoom. Each event's `deltaY` stays under 4 pixels, where
/// both take it for a trackpad rather than a mouse wheel and zoom smoothly
/// instead of a step at a time. `pixelsPerZoom` sits between the two:
/// OpenLayers zooms one level per 100 pixels of pinch, MapLibre per about 140.
///
/// A rotation turns the 3D map through core's `window.lm.turnMap(degrees)`,
/// clockwise since the fingers went down and null when they lift: no event
/// carries a rotation, and a synthetic right-button drag only made the map
/// shake. The 2D map does not turn, and a page from before `turnMap` ignores
/// the rotation.
///
/// A trackpad reports every two-finger gesture to both recognizers, so a
/// pinch may turn a little and a twist scale a little. A gesture is locked to
/// whichever passes its threshold first (`zoomThreshold`, `turnThreshold`),
/// and the other is ignored until the fingers lift.
@MainActor
enum TrackpadBridge {
    /// Whether the app runs on a Mac, where the trackpad needs handing on.
    static let isNeeded = ProcessInfo.processInfo.isiOSAppOnMac

    static let pixelsPerZoom = 120.0
    /// Zoom levels a pinch must change before it counts as one.
    static let zoomThreshold = 0.08
    /// Radians a rotation must turn before it counts as one (8°).
    static let turnThreshold = 8 * Double.pi / 180
    private static let maxStep = 3.5

    private enum Lock { case undecided, zoom, turn }
    private static var lock = Lock.undecided
    private static var pinching = false
    private static var rotating = false
    /// The scale the page has been told about.
    private static var toldScale: CGFloat = 1
    /// The rotation at which the turn started, so the map does not jump by the threshold.
    private static var turnOrigin: CGFloat = 0

    /// Call for every state of a pinch recognizer on the map.
    static func pinch(_ recognizer: UIPinchGestureRecognizer, in webView: WKWebView) {
        guard isNeeded else { return }
        switch recognizer.state {
        case .began:
            pinching = true
            toldScale = 1
        case .changed:
            guard recognizer.scale > 0 else { return }
            if lock == .undecided, abs(log2(Double(recognizer.scale))) > zoomThreshold { lock = .zoom }
            guard lock == .zoom else { return }
            let zoom = log2(Double(recognizer.scale / toldScale))
            toldScale = recognizer.scale
            dispatchWheel(deltaY: -zoom * pixelsPerZoom, at: recognizer.location(in: webView), in: webView)
        default:
            pinching = false
            release()
        }
    }

    /// Call for every state of a rotation recognizer on the map.
    static func rotate(_ recognizer: UIRotationGestureRecognizer, in webView: WKWebView) {
        guard isNeeded else { return }
        switch recognizer.state {
        case .began:
            rotating = true
        case .changed:
            if lock == .undecided, abs(Double(recognizer.rotation)) > turnThreshold {
                lock = .turn
                turnOrigin = recognizer.rotation
            }
            guard lock == .turn else { return }
            let degrees = Double(recognizer.rotation - turnOrigin) * 180 / .pi
            webView.evaluateJavaScript("window.lm?.turnMap?.(\(degrees));", completionHandler: nil)
        default:
            rotating = false
            if lock == .turn {
                webView.evaluateJavaScript("window.lm?.turnMap?.(null);", completionHandler: nil)
            }
            release()
        }
    }

    /// Unlocks once both recognizers have ended.
    private static func release() {
        if !pinching && !rotating { lock = .undecided }
    }

    /// `deltaY` as `wheel` events with `ctrlKey`, each under `maxStep`, at
    /// `point` (CSS pixels: the page is never zoomed).
    private static func dispatchWheel(deltaY: Double, at point: CGPoint, in webView: WKWebView) {
        guard deltaY.isFinite, abs(deltaY) > 0.01 else { return }
        let count = Int((abs(deltaY) / maxStep).rounded(.up))
        let step = deltaY / Double(count)
        webView.evaluateJavaScript("""
        (() => {
          const x = \(point.x), y = \(point.y);
          const target = document.elementFromPoint(x, y) || document.body;
          for (let i = 0; i < \(count); i++) {
            target.dispatchEvent(new WheelEvent("wheel", { deltaY: \(step), deltaMode: 0, ctrlKey: true,
              clientX: x, clientY: y, bubbles: true, cancelable: true, composed: true }));
          }
        })();
        """, completionHandler: nil)
    }
}

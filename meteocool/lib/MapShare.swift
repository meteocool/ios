//
//  MapShare.swift
//  meteocool
//
//  A link to what the map shows, as the page hands it over for sharing.
//

import Foundation
import CoreGraphics

/// A link to what the map shows, from core's `lib/share.ts`: the body of a
/// `share:` message from one of the page's share buttons, or the answer to
/// `window.shareLink()` when the app starts the share itself (a screenshot).
///
/// The page builds the link, because only the page knows what is on screen:
/// the map, the view, the storm, the frame. The link carries when it was
/// shared (`shared=`), so whoever opens it later is told how old it is.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
struct MapShare: Equatable {
    let url: URL
    /// For the share sheet's header and a mail's subject.
    let title: String
    /// The control the share was asked from, in the web view's points (a CSS
    /// pixel is a point: the page is never zoomed). An iPad's popover points
    /// at it. Nil for a share the app started.
    let sourceRect: CGRect?

    /// The longest title passed on. The page's are a place name and the app's
    /// name; anything longer is not one of those.
    static let maxTitleLength = 200

    /// Reads a share from the page's JSON. Nil for anything that is not a
    /// link back to the map host the app loaded (`mapHost`), so the share
    /// sheet can only ever offer a meteocool link: the page is the app's own,
    /// but its strings are still checked before use.
    init?(json: String, mapHost: String?) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["url"] as? String,
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              let mapHost, host == mapHost.lowercased() else { return nil }
        // Plain http only for a map served from the loopback, which only the
        // simulator's test builds load.
        guard scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost"].contains(host)) else { return nil }
        self.url = url

        let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = title.isEmpty ? "meteocool" : String(title.prefix(Self.maxTitleLength))

        if let x = Self.number(object["x"]), let y = Self.number(object["y"]),
           let width = Self.number(object["width"]), let height = Self.number(object["height"]),
           width >= 0, height >= 0 {
            sourceRect = CGRect(x: x, y: y, width: width, height: height)
        } else {
            sourceRect = nil
        }
    }

    /// The link's search without what makes it a shared link (the `shared`
    /// stamp and the sharer's `share_lang`): the view on screen, to open
    /// again after the page died. Without the stamp the page does not
    /// announce it as a link shared some time ago (core's `lib/shareLink.ts`).
    var viewSearch: String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = components.queryItems?.filter { $0.name != "shared" && $0.name != "share_lang" }
        guard let query = components.percentEncodedQuery, !query.isEmpty else { return nil }
        return "?" + query
    }

    /// A finite number from JSON, which arrives as `NSNumber`.
    private static func number(_ value: Any?) -> CGFloat? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? CGFloat(double) : nil
    }
}

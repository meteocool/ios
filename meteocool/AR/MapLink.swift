//
//  MapLink.swift
//  meteocool
//
//  The way back from the AR view to the same storm on the map.
//

import Foundation

/// The search part of a link that opens a storm on the 3D map, in the
/// parameters core's deep links read (`src/lib/deepLink.ts`).
enum MapLink {
    /// A tracked cell wins over its box, as core settles it: the cell has a
    /// track and a history, the box only a volume.
    static func search(for entry: StormEntry, cell: TrackedCell?) -> String? {
        if let code = cell?.code, isCellCode(code) {
            return "?layer=cells3d&cell=\(code)"
        }
        guard let link = cloudLink(entry.path) else { return nil }
        return "?layer=cells3d&cloud=\(link)"
    }

    /// `meteoradar/volumes/20260924T194500/de-G1401218632.mcvx` to
    /// `20260924T194500/de-G1401218632`, as core's `cloudLink`.
    static func cloudLink(_ path: String) -> String? {
        let pattern = #"^meteoradar/volumes/(\d{8}T\d{6})/((?:[a-z]{2}-)?(?:G\d{10}|R\d{1,12}))\.mcvx$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let scan = Range(match.range(at: 1), in: path), let name = Range(match.range(at: 2), in: path) else { return nil }
        return "\(path[scan])/\(path[name])"
    }

    /// A volume path, as the map names it in `openAR:` and `cloudSelected:`.
    static func isVolumePath(_ value: String) -> Bool { cloudLink(value) != nil }

    /// A KONRAD3D track code: 22 digits.
    static func isCellCode(_ value: String) -> Bool {
        value.count == 22 && value.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// JavaScript that opens a link's search in the map without reloading
    /// it: through `window.openLink` where core has it, and otherwise the way
    /// the browser's back button does, which core's urlState already follows.
    static func openScript(search: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [search]),
              let array = String(data: data, encoding: .utf8) else { return nil }
        return """
        (function (search) {
          if (typeof window.openLink === "function") { window.openLink(search); return; }
          window.history.pushState(window.history.state, "", search);
          window.dispatchEvent(new PopStateEvent("popstate", { state: window.history.state }));
        })(\(array)[0]);
        """
    }
}

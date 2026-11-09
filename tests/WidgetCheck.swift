import CoreLocation
import Foundation

/// Checks the widgets' maths: moving now along a forecast between timeline
/// entries, the chart's window, and snapping a preview card the way the API's
/// preview images (`/v3/preview/og.png`) are snapped, whose cache the
/// widgets share and whose snapped centre places the marker on the map.
@main
struct WidgetCheck {
    static func main() {
        let start = 1_000_000_200
        let forecast = RainForecast(start: start, interval: 300, dbz: [0, 0, 0, 0, 25, 30, 22, 8, 0, 0, nil],
                                    observed: 2, threshold: 20)

        let available = forecast.advanced(to: forecast.now)
        precondition(available.dbz.count == 10 && available.phase == forecast.phase,
                     "An absent forecast tail must not hide known upcoming rain")
        precondition(forecast.end == Date(timeIntervalSince1970: 1_000_003_200),
                     "The forecast must expire before its absent tail")
        var gaps = forecast
        gaps.dbz[4] = nil
        precondition(gaps.advanced(to: gaps.now).dbz[4] == nil,
                     "An internal gap must remain unknown")
        gaps.dbz = [nil, nil]
        precondition(gaps.advanced(to: gaps.now).dbz.isEmpty,
                     "An entirely absent forecast must not become dry readings")
        gaps.dbz = [0, 25, 25, nil, nil]
        let ongoing = gaps.advanced(to: gaps.now)
        precondition(ongoing.phase == .raining(end: nil),
                     "An absent tail cannot prove that ongoing rain stops")
        gaps.headline = .init(title: "Rain until {at:end}", times: ["end": start + 3 * 300])
        gaps.headlines = [String(start + gaps.observed * 300): gaps.headline!]
        precondition(gaps.advanced(to: gaps.now).currentHeadline == nil,
                     "Backend wording inferred from the absent tail must not promise a rain end")

        // Now moves with the clock, a step at a time, and never back.
        precondition(forecast.advanced(to: Date(timeIntervalSince1970: TimeInterval(start + 2 * 300 + 10))).observed == 2)
        precondition(forecast.advanced(to: Date(timeIntervalSince1970: TimeInterval(start + 3 * 300 + 299))).observed == 3)
        precondition(forecast.advanced(to: Date(timeIntervalSince1970: TimeInterval(start))).observed == 2)
        precondition(forecast.advanced(to: Date(timeIntervalSince1970: TimeInterval(start + 99 * 300))).observed == 10)
        // Rain two steps away becomes rain now once now has moved to it.
        let later = forecast.advanced(to: forecast.date(at: 5))
        precondition(later.phase == .raining(end: later.date(at: 7)), "\(later.phase)")

        // The window keeps the last past step, `past` more before it, and
        // `ahead` steps from now.
        let window = forecast.advanced(to: forecast.date(at: 4)).window(past: 1, ahead: 3)
        precondition(window.observed == 2 && window.dbz == [0, 0, 25, 30, 22] && window.start == start + 2 * 300, "\(window)")
        precondition(forecast.rainMinutes(ahead: 6) == 15)
        precondition(forecast.end == forecast.date(at: 10))

        // The backend's headlines follow now as it moves; past them, none.
        let json = """
        {"frames": {"1000000200": {"dbz": 0, "source": "observation"}, "1000000500": {"dbz": 30, "source": "observation"},
                    "1000000800": {"dbz": 45, "source": "nowcast_phys"}, "1000001100": {"dbz": 0, "source": "nowcast_phys"}},
         "headlines": {"1000000800": {"title": "Rain until {at:end}", "detail": null, "intensity": "Rain",
                                      "times": {"end": 1000001100}},
                       "1000001100": {"title": "No precipitation expected", "detail": null, "intensity": null,
                                      "times": {}}},
         "words": [{"above": 40, "text": "Heavy rain"}, {"above": 25, "text": "Rain"}]}
        """
        let worded = RainForecast.fromTimeseries(Data(json.utf8), threshold: 20)!
        precondition(worded.currentHeadline?.title == "Rain until {at:end}", "\(String(describing: worded.currentHeadline))")
        let moved = worded.advanced(to: worded.date(at: 3))
        precondition(moved.currentHeadline?.title == "No precipitation expected")
        precondition(moved.currentHeadline?.times == [:])
        precondition(worded.advanced(to: worded.date(at: 9)).currentHeadline == nil)
        precondition(worded.word(dbz: 45) == "Heavy rain" && worded.word(dbz: 30) == "Rain" && worded.word(dbz: 10) == nil)
        let cached = try! JSONDecoder().decode(RainForecast.self, from: JSONEncoder().encode(worded))
        precondition(cached == worded)

        // The gallery's shower arrives ahead and ends.
        if case .approaching = RainForecast.sample().phase {} else { preconditionFailure("sample") }

        // Snapped as card.ts snaps them (values from its parseCard).
        let cards: [(Double, Double, Double, Double, Double, Double)] = [
            (48.1372, 11.5755, 9.5, 48.14940, 11.60246, 9.5),
            (47.8, 12.1, 9.3, 47.81661, 12.09964, 9.5),
            (-33.86, 151.21, 11, -33.85217, 151.21582, 11),
            (64.1, -21.9, 6.6, 64.02324, -21.89534, 6.5),
        ]
        for (latitude, longitude, zoom, snappedLatitude, snappedLongitude, snappedZoom) in cards {
            let card = PreviewCard(latitude: latitude, longitude: longitude, zoom: zoom, wide: false)
            precondition(abs(card.latitude - snappedLatitude) < 1e-5 && abs(card.longitude - snappedLongitude) < 1e-5
                         && card.zoom == snappedZoom, "\(card)")
            // The place is within half a grid step of the card's centre.
            let position = card.position(of: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            precondition(abs(position.x - 0.5) * 1024 <= 16.01 && abs(position.y - 0.5) * 1024 <= 16.01, "\(position)")
        }
        let centre = PreviewCard(latitude: 47.81661, longitude: 12.09964, zoom: 9.5, wide: true)
        let position = centre.position(of: CLLocationCoordinate2D(latitude: centre.latitude, longitude: centre.longitude))
        precondition(abs(position.x - 0.5) < 1e-6 && abs(position.y - 0.5) < 1e-6)
        precondition(centre.key == "47.81661,12.09964,9.5,wide")
        let equator = PreviewCard(latitude: 0, longitude: 0, zoom: 8, wide: false)
        let east = CLLocationCoordinate2D(latitude: 0, longitude: 0.17578125)
        let point = equator.position(of: east, croppedTo: CGSize(width: 660, height: 1248),
                                     displayedIn: CGSize(width: 330, height: 400))
        precondition(abs(point.x - 184.5) < 1e-6 && abs(point.y - 200) < 1e-6,
                     "Location marker must keep its position when rows crop the map: \(point)")
        print("Widget checks passed")
    }
}

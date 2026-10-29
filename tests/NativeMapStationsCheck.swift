import Foundation

/// Checks the weather stations' rules (`meteocool/NativeMap/Stations/StationRules.swift`)
/// with core's own tests: `scripts/tests/stations.test.ts`, `windBarb.test.ts`
/// and `stationHistory.test.ts`.
@main
struct NativeMapStationsCheck {
    static var count = 0

    static func test(_ name: String, _ body: () -> Void) {
        body()
        count += 1
    }

    static func main() {
        stations()
        barbs()
        history()
        print("NativeMapStationsCheck: \(count) checks passed")
    }

    static func station(_ values: [String: Double]) -> ObservedStation {
        ObservedStation(id: "1", lat: 50, lon: 10, name: "Somewhere", state: "Hessen", elevationM: 300,
                        observedAt: "2026-10-27T00:10:00Z", values: values)
    }

    static func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) < tolerance }

    static func stations() {
        typealias R = StationRules
        let newest = 1_790_000_000
        test("each choice asks for its own parameters, wind first and the default") {
            precondition(R.parameters(.wind) == ["wind_speed_m_s", "wind_direction_deg"])
            precondition(R.parameters(.gusts) == ["gust_m_s", "gust_direction_deg"])
            precondition(R.parameters(.temperature) == ["temperature_c"] && R.parameters(.precipitation) == ["precipitation_mm"])
            precondition(R.parameters(.humidity) == ["humidity_pct"] && R.parameters(.pressure) == ["pressure_msl_hpa"])
            precondition(StationChoice.allCases.map(\.rawValue) == ["wind", "gusts", "temperature", "precipitation", "humidity", "pressure"])
            precondition(R.defaultChoice == .wind)
            precondition(R.parseChoice("humidity") == .humidity && R.parseChoice("cloud_cover") == .wind && R.parseChoice(nil) == .wind)
        }
        test("live and on a forecast frame the newest; in the past, the ones from then") {
            precondition(R.at(shown: newest, newest: newest) == nil)
            precondition(R.at(shown: newest - 1800, newest: newest) == newest - 1800)
            precondition(R.at(shown: newest + 900, newest: newest) == nil)
            precondition(R.at(shown: 0, newest: 0) == nil && R.at(shown: newest - 600, newest: 0) == nil)
        }
        test("on a forecast frame the stations are greyed; live, in the past and with no grid they are not") {
            precondition(R.stale(shown: newest + 300, newest: newest))
            precondition(!R.stale(shown: newest, newest: newest) && !R.stale(shown: newest - 1800, newest: newest))
            precondition(!R.stale(shown: 0, newest: newest) && !R.stale(shown: newest + 300, newest: 0))
        }
        test("a barb's wind is in knots, from the gust's own direction for gusts; none without both") {
            let values = station(["wind_speed_m_s": 5, "wind_direction_deg": 280, "gust_m_s": 9, "gust_direction_deg": 260])
            let wind = R.wind(.wind, values)!
            precondition(close(wind.knots, 9.71922, 1e-4) && wind.fromDeg == 280)
            precondition(R.wind(.gusts, values)!.fromDeg == 260)
            precondition(R.wind(.wind, station(["wind_speed_m_s": 3])) == nil)
            precondition(R.wind(.gusts, station(["wind_speed_m_s": 3, "wind_direction_deg": 90])) == nil)
        }
        test("a value is the choice's own parameter, and missing when not reported") {
            precondition(R.value(.temperature, station(["temperature_c": 7.3])) == 7.3)
            precondition(R.value(.pressure, station(["pressure_hpa": 905])) == nil)
            precondition(R.value(.wind, station(["wind_speed_m_s": 3])) == nil)
        }
        test("values read with one decimal, humidity whole, the reader's decimal mark, never grouped, never -0") {
            precondition(R.formatValue(.temperature, 7.26) == "7.3" && R.formatValue(.pressure, 1013) == "1013.0")
            precondition(R.formatValue(.precipitation, 0.04) == "0.0" && R.formatValue(.humidity, 86.6) == "87")
            precondition(R.formatValue(.temperature, 7.26, language: "de") == "7,3")
            precondition(R.formatValue(.pressure, 1013.04, language: "de") == "1013,0")
            precondition(R.formatValue(.temperature, -0.04) == "0.0" && R.formatValue(.humidity, -0.2) == "0")
        }
        test("temperatures are coloured by band; rain at the reflectivity its rate would show") {
            precondition(Set([-20.0, -5, 5, 15, 25, 35].map(R.temperatureColour)).count == 6)
            precondition(R.temperatureColour(0) == R.temperatureColour(5) && R.temperatureColour(-0.1) == R.temperatureColour(-5))
            precondition(R.precipitationDbz(0) == nil && R.precipitationDbz(0.04) == nil)
            precondition(close(R.precipitationDbz(0.1)!, 19.46, 0.05) && R.precipitationDbz(2)! > R.precipitationDbz(0.5)!)
        }
        test("from zoom 8 in every station is shown; further out thinned, the nearest the middle or the higher ranked kept") {
            precondition(R.thinningCell(8) == 0 && R.thinningCell(11) == 0 && R.thinningCell(6) > 0 && R.thinningCell(7.9) > 0)
            let kept = R.thinToGrid([R.Placed(id: "corner", x: 2, y: 2, rank: 0), R.Placed(id: "middle", x: 21, y: 23, rank: 0),
                                     R.Placed(id: "next", x: 60, y: 20, rank: 0)], cell: 44)
            precondition(kept == ["middle", "next"])
            precondition(R.thinToGrid([R.Placed(id: "dry", x: 22, y: 22, rank: 0), R.Placed(id: "wet", x: 3, y: 40, rank: 0.4)], cell: 44) == ["wet"])
            precondition(R.thinToGrid([R.Placed(id: "a", x: 1, y: 1, rank: 0), R.Placed(id: "b", x: 2, y: 2, rank: 0)], cell: 0).count == 2)
        }
        test("an answer decodes, its zeros kept") {
            let json = """
            {"type":"FeatureCollection","features":[{"type":"Feature","id":"00090","geometry":{"type":"Point","coordinates":[9.2583,50.7557]},
             "properties":{"wind_speed_m_s":0.9,"wind_direction_deg":0,"precipitation_mm":0,"station":"00090","name":"Alsfeld","state":"Hessen",
             "elevation_m":305.0,"datasets":["wind"],"observed_at":"2026-10-29T00:20:00Z"}}]}
            """
            let stations = ObservedStation.decode(Data(json.utf8))!
            precondition(stations.count == 1 && stations[0].name == "Alsfeld" && stations[0].elevationM == 305)
            precondition(stations[0].values["wind_direction_deg"] == 0 && stations[0].values["precipitation_mm"] == 0)
            precondition(stations[0].values["elevation_m"] == nil)
        }
    }

    static func barbs() {
        func barb(_ knots: Double, _ from: Double = 270) -> (knots: Double, shaft: (WindBarb.Point, WindBarb.Point),
                                                             feathers: [(WindBarb.Point, WindBarb.Point)], pennants: [(WindBarb.Point, WindBarb.Point, WindBarb.Point)]) {
            guard case .barb(let k, let shaft, let feathers, let pennants) = WindBarb.shape(knots: knots, fromDeg: from) else { preconditionFailure("calm") }
            return (k, shaft, feathers, pennants)
        }
        func length(_ a: WindBarb.Point, _ b: WindBarb.Point) -> Double { hypot(b.x - a.x, b.y - a.y) }
        test("knots, rounded to the nearest five; calm below 2.5") {
            precondition(close(WindBarb.toKnots(1), 1.943844) && close(WindBarb.toKnots(10), 19.43844))
            precondition(WindBarb.roundKnots(7.4) == 5 && WindBarb.roundKnots(7.5) == 10 && WindBarb.roundKnots(12.4) == 10 && WindBarb.roundKnots(0) == 0)
            if case .calm(let radius) = WindBarb.shape(knots: 2.4, fromDeg: 90) { precondition(radius == WindBarb.calm) } else { preconditionFailure() }
            if case .calm = WindBarb.shape(knots: 2.5, fromDeg: 90) { preconditionFailure() }
        }
        test("5 kt is a lone half feather a step in; 10 a full one at the end; 15 both") {
            let five = barb(5)
            precondition(five.pennants.isEmpty && five.feathers.count == 1)
            precondition(close(length(five.feathers[0].0, five.feathers[0].1) / hypot(1, 0.45), WindBarb.feather / 2))
            precondition(close(length(five.feathers[0].0, five.shaft.1), WindBarb.step))
            let ten = barb(10)
            precondition(ten.feathers.count == 1 && close(length(ten.feathers[0].0, ten.shaft.1), 0))
            let fifteen = barb(15)
            precondition(fifteen.feathers.count == 2 && close(length(fifteen.feathers[1].0, fifteen.shaft.1), WindBarb.step))
        }
        test("50 kt is a pennant; 65 a pennant, a full and a half; 145 two pennants and the shaft grown") {
            let fifty = barb(50)
            precondition(fifty.pennants.count == 1 && fifty.feathers.isEmpty)
            precondition(close(length(fifty.pennants[0].1, fifty.shaft.1), WindBarb.pennant))
            let sixtyFive = barb(65)
            precondition(sixtyFive.pennants.count == 1 && sixtyFive.feathers.count == 2)
            let strong = barb(145)
            precondition(strong.pennants.count == 2 && strong.feathers.count == 5)
            let innermost = strong.feathers.map { length($0.0, strong.shaft.1) }.max()!
            precondition(length(strong.shaft.0, strong.shaft.1) - innermost >= WindBarb.step * 2 - 1e-9)
        }
        test("the shaft points where the wind comes from, and a westerly's feathers stand to the north") {
            func end(_ from: Double) -> (Double, Double) { let p = barb(10, from).shaft.1; return (p.x.rounded() + 0, p.y.rounded() + 0) }
            precondition(end(0) == (0, -WindBarb.shaft) && end(90) == (WindBarb.shaft, 0))
            precondition(end(180) == (0, WindBarb.shaft) && end(270) == (-WindBarb.shaft, 0))
            for (base, tip) in barb(25, 270).feathers { precondition(tip.y < base.y - 5) }
            for (_, _, apex) in barb(50, 270).pennants { precondition(apex.y < -5) }
            for (base, tip) in barb(25, 0).feathers { precondition(tip.x > base.x + 5) }
            for (base, tip) in barb(20, 270).feathers { precondition(tip.x < base.x) }
        }
    }

    static func history() {
        let t0 = 1_793_059_200_000.0 // 2026-10-27T00:00Z
        func row(_ minutes: Double, _ values: [String: Double]) -> ObservationRow { ObservationRow(t: t0 + minutes * 60_000, values: values) }
        func stat(_ rows: [ObservationRow], _ key: String, _ which: String) -> Double? {
            StationHistory.panels(rows).first { $0.key == key }?.stats.first { $0.key == which }?.value
        }
        test("no rows no panels; wind alone its own; all of them in their order") {
            precondition(StationHistory.panels([]).isEmpty)
            precondition(StationHistory.panels([row(10, ["wind_speed_m_s": 2, "wind_direction_deg": 220, "gust_m_s": 4])]).map(\.key) == ["wind", "direction"])
            let all = [row(10, ["temperature_c": 10, "precipitation_mm": 0, "sunshine_minutes": 0, "humidity_pct": 80, "pressure_msl_hpa": 1015,
                                "wind_speed_m_s": 2, "wind_direction_deg": 90])]
            precondition(StationHistory.panels(all).map(\.key) == ["temperature", "precipitation", "sunshine", "humidity", "pressure", "wind", "direction"])
        }
        test("temperature extremes from DWD's own ten-minute extremes, else the readings'") {
            let rows = [row(10, ["temperature_c": 10, "temperature_max_c": 10.4, "temperature_min_c": 9.8]),
                        row(20, ["temperature_c": 12, "temperature_max_c": 12.6, "temperature_min_c": 11.9])]
            precondition(stat(rows, "temperature", "max") == 12.6 && stat(rows, "temperature", "min") == 9.8 && stat(rows, "temperature", "mean") == 11)
            let plain = [row(10, ["temperature_c": 10]), row(20, ["temperature_c": 12])]
            precondition(stat(plain, "temperature", "max") == 12 && stat(plain, "temperature", "min") == 10)
        }
        test("rain summed (a dry week kept), sunshine in hours, pressure's change, wind's gust and mean") {
            precondition(stat([row(10, ["precipitation_mm": 0]), row(20, ["precipitation_mm": 0])], "precipitation", "total") == 0)
            let rows = [row(10, ["precipitation_mm": 0.3, "sunshine_minutes": 10]), row(20, ["precipitation_mm": 1.2, "sunshine_minutes": 8]),
                        row(30, ["sunshine_minutes": 12])]
            precondition(close(stat(rows, "precipitation", "total")!, 1.5) && stat(rows, "sunshine", "total") == 0.5)
            precondition(stat([row(10, ["pressure_msl_hpa": 1016]), row(20, [:]), row(30, ["pressure_msl_hpa": 1013.5])], "pressure", "change") == -2.5)
            let wind = [row(10, ["wind_speed_m_s": 2, "gust_m_s": 5]), row(20, ["wind_speed_m_s": 4, "gust_m_s": 9.1])]
            precondition(stat(wind, "wind", "gust") == 9.1 && stat(wind, "wind", "mean") == 3)
        }
        test("a window starts its hours before now; a line is lifted across a long gap") {
            let now = t0 + 36 * 3_600_000
            precondition(StationHistory.windowStart(.day, now: now) == now - 24 * 3_600_000)
            precondition(StationHistory.windowStart(.week, now: now) == now - 168 * 3_600_000)
            let points = [StationHistory.Point(t: 0, v: 1), StationHistory.Point(t: 600_000, v: 2), StationHistory.Point(t: 6_000_000, v: 3)]
            precondition(StationHistory.runs(points).map(\.count) == [2, 1])
        }
    }
}

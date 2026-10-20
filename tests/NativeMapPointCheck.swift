import Foundation
import CoreGraphics

/// Checks the native map's held point and its other maps: the point menu's
/// placement, links with a point and a layer, the dryness verdict, place
/// names, the model comparison's consensus and outlook (core's
/// `scripts/tests/outlook.test.ts`, `dryness.test.ts`), the lightning
/// palette, strikes and histogram (`lightningChart.test.ts`), and the
/// precipitation classes (`hgClasses.test.ts`).
@main
struct NativeMapPointCheck {
    static func near(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= tolerance
    }

    static func main() {
        placement()
        links()
        dryness()
        places()
        consensus()
        openMeteo()
        outlook()
        axes()
        lightning()
        precipTypes()
        print("NativeMapPointCheck: all checks passed")
    }

    // MARK: Point menu

    static func placement() {
        let width = 402.0
        // Mid-screen: above, centred.
        precondition(PointMenuLayout.placement(x: 200, y: 400, width: width, shareAvailable: true)
            == .init(below: false, side: .center, lean: 0))
        // Near the top: 170 pt without the share row, 226 with it.
        precondition(PointMenuLayout.placement(x: 200, y: 169, width: width, shareAvailable: false).below)
        precondition(!PointMenuLayout.placement(x: 200, y: 170, width: width, shareAvailable: false).below)
        precondition(PointMenuLayout.placement(x: 200, y: 225, width: width, shareAvailable: true).below)
        precondition(!PointMenuLayout.placement(x: 200, y: 226, width: width, shareAvailable: true).below)
        // Near the edges it leans inwards, 30 pt past the point, but stays 8 pt in.
        precondition(PointMenuLayout.placement(x: 100, y: 400, width: width, shareAvailable: true)
            == .init(below: false, side: .left, lean: 30))
        precondition(PointMenuLayout.placement(x: 20, y: 400, width: width, shareAvailable: true).lean == 12)
        precondition(PointMenuLayout.placement(x: 4, y: 400, width: width, shareAvailable: true).lean == 0)
        precondition(PointMenuLayout.placement(x: 390, y: 400, width: width, shareAvailable: true)
            == .init(below: false, side: .right, lean: 4))
        precondition(PointMenuLayout.placement(x: 120, y: 400, width: width, shareAvailable: true).side == .center)
        precondition(LongPress.duration == 0.45 && LongPress.slop == 10)
    }

    // MARK: Links

    static func links() {
        // core's parsePair: both valid or nothing.
        precondition(PointLink.parsePair("48.137,11.575")! == (48.137, 11.575))
        precondition(PointLink.parsePair(" 48.1 , 11.5 ")! == (48.1, 11.5))
        precondition(PointLink.parsePair("91,11") == nil && PointLink.parsePair("48,181") == nil)
        precondition(PointLink.parsePair("48") == nil && PointLink.parsePair("48,11,3") == nil)
        precondition(PointLink.parsePair("48,") == nil && PointLink.parsePair(nil) == nil && PointLink.parsePair("a,b") == nil)
        precondition(PointLink.pair(latitude: 48.137, longitude: 11.575) == "48.13700,11.57500")
        precondition(PointLink.pair(latitude: -0.000001, longitude: 0) == "0.00000,0.00000")
        precondition(PointLink.view(latitude: 48.137, longitude: 11.575, zoom: 8) == "48.13700,11.57500,8.00")
        // Layers: a plain word.
        precondition(PointLink.validLayer("precipTypes") && PointLink.validLayer("radar"))
        precondition(!PointLink.validLayer("") && !PointLink.validLayer("radar;x") && !PointLink.validLayer(String(repeating: "a", count: 33)))
        // core's order, foreign parameters first, separators readable.
        let shared = PointLink.search("?latLonZ=1.00000,2.00000,6.00&shared=20261020T0030Z&layer=radar&share_lang=de",
                                      changing: ["point": "48.13700,11.57500", "latLonZ": "48.13700,11.57500,8.00"])
        precondition(shared == "?share_lang=de&layer=radar&latLonZ=48.13700,11.57500,8.00&point=48.13700,11.57500&shared=20261020T0030Z",
                     shared)
        precondition(PointLink.search("?point=1,2&t=20261020T0000Z", changing: ["point": nil]) == "?t=20261020T0000Z")
        precondition(PointLink.search("", changing: [:]) == "")
    }

    // MARK: Dryness (core's dryness.test.ts)

    static func dryness() {
        precondition(Dryness.isDry([-32.5, -32.5, 0]))
        precondition(!Dryness.isDry([-32.5, 12.4, -32.5]))
        precondition(!Dryness.isDry([nil, nil]) && !Dryness.isDry([]))
        precondition(Dryness.isDry([nil, -32.5, nil]))
        // The boxes: Munich in, New York out; a view over Brittany is covered.
        precondition(RadarExtents.covers(latitude: 48.137, longitude: 11.575))
        precondition(!RadarExtents.covers(latitude: 40.7, longitude: -74))
        precondition(RadarExtents.overlapsAny(minLon: -5, minLat: 47, maxLon: -3, maxLat: 49))
        precondition(!RadarExtents.overlapsAny(minLon: -80, minLat: 30, maxLon: -70, maxLat: 40))
    }

    // MARK: Places (core's reverseGeocode.ts)

    static func places() {
        let nominatim = GeoPlace.nominatim(Data("""
        {"address":{"suburb":"Altstadt-Lehel","city":"München","county":"Landkreis München","state":"Bayern","country":"Deutschland"}}
        """.utf8))!
        precondition(nominatim.label(.local) == "München" && nominatim.label(.regional) == "Bayern"
            && nominatim.label(.country) == "Deutschland")
        precondition(nominatim.near == NearPlace(name: "München", district: "Altstadt-Lehel"))
        precondition(nominatim.near!.title(withDistrict: true) == "Altstadt-Lehel, München")
        precondition(nominatim.near!.title(withDistrict: false) == "München")
        // A town or a village stands in for the city; the state falls back to the county.
        let village = GeoPlace.nominatim(Data(#"{"address":{"village":"Dorf","hamlet":"Dorf","county":"Kreis"}}"#.utf8))!
        precondition(village.city == "Dorf" && village.principalSubdivision == "Kreis" && village.near?.district == nil)
        // Nothing there is a 200 with an error, which is no place.
        precondition(GeoPlace.nominatim(Data(#"{"error":"Unable to geocode"}"#.utf8)) == nil)
        // BigDataCloud at sea: the zone is not a locality, the sea is the name.
        let sea = GeoPlace.bigDataCloud(Data("""
        {"city":"","locality":"German EEZ","principalSubdivision":"","countryName":"",
         "localityInfo":{"administrative":[],"informative":[{"name":"Europe/Berlin","description":"time zone"},
          {"name":"Exclusive Economic Zone"},{"name":"North Sea","description":"sea"}]}}
        """.utf8))!
        precondition(sea.locality == nil && sea.sea == "North Sea" && sea.label(.local) == "North Sea")
        let land = GeoPlace.bigDataCloud(Data("""
        {"city":"Munich","locality":"Maxvorstadt","principalSubdivision":"Bavaria","countryName":"Germany",
         "localityInfo":{"administrative":[{"name":"Upper Bavaria","adminLevel":5},{"name":"Munich","adminLevel":6}]}}
        """.utf8))!
        precondition(land.county == "Munich" && land.sea == nil && land.label(.regional) == "Bavaria")
        precondition(GeocodeScale.forZoom(9) == .local && GeocodeScale.forZoom(8.9) == .regional
            && GeocodeScale.forZoom(6) == .regional && GeocodeScale.forZoom(5.9) == .country)
        precondition(GeocodeScale.local.nominatimZoom == 12 && GeocodeScale.regional.nominatimZoom == 8
            && GeocodeScale.country.nominatimZoom == 3)
        precondition(ReverseGeocoder.key(latitude: 48.13749, longitude: 11.5751, language: "de", kind: "near") == "48.137,11.575,de,near")
        precondition(ReverseGeocoder.language("de-DE") == "de")
        let url = ReverseGeocoder.nominatimURL(base: URL(string: "https://geocoding-staging.meteocool.com")!, latitude: 48.137,
                                               longitude: 11.575, language: "en", zoom: 12)!
        precondition(url.absoluteString
            == "https://geocoding-staging.meteocool.com/reverse?lat=48.137&lon=11.575&format=jsonv2&zoom=12&accept-language=en")
    }

    // MARK: Consensus (core's consensus.ts)

    static func consensus() {
        precondition(CompareModels.all.count == 21 && CompareModels.ids.first == "ecmwf_ifs")
        // Four ICONs are 2.5 opinions, not four.
        precondition(CompareModels.effectiveCount(["icon_global", "icon_eu", "icon_d2", "meteoswiss_icon_seamless"]) == 2.5)
        precondition(CompareModels.effectiveCount(["ecmwf_ifs", "gfs_seamless", "ukmo_seamless"]) == 3)
        precondition(Consensus.tier(0.7) == .high && Consensus.tier(0.69) == .mid && Consensus.tier(0.4) == .mid
            && Consensus.tier(0.39) == .low)
        precondition(Consensus.typicalSpread(.temperatureMax, leadHours: 24) == 1)
        precondition(Consensus.typicalSpread(.temperatureMax, leadHours: 48) == 1.5)
        precondition(Consensus.typicalSpread(.temperatureMin, leadHours: 120) == 2.75)
        precondition(Consensus.typicalSpread(.temperatureMin, leadHours: 200) == 3.5)
        precondition(Consensus.typicalSpread(.precipitationSum, leadHours: 49) == 10)
        precondition(near(Consensus.weight("icon_d2", .precipitationSum), 1.43))
        precondition(Consensus.weight("ecmwf_aifs025_single", .temperatureMax) == 0.8 && Consensus.weight("nobody", .weatherCode) == 1)
        precondition(Consensus.of([], .temperatureMax, leadHours: 0) == .empty)

        // Three agreeing global models: full agreement.
        let agreed = Consensus.of([ModelValue(id: "ecmwf_ifs", value: 20), ModelValue(id: "gfs_seamless", value: 20),
                                   ModelValue(id: "ukmo_seamless", value: 20)], .temperatureMax, leadHours: 12)
        precondition(agreed.value == 20 && agreed.stdDev == 0 && agreed.predictability == 1 && Consensus.tier(agreed.predictability) == .high)
        // Spread across them, weighted: mean 20, sd sqrt(8/3), score 1 - sd/1 < 0.
        let spread = Consensus.of([ModelValue(id: "ecmwf_ifs", value: 18), ModelValue(id: "gfs_seamless", value: 20),
                                   ModelValue(id: "ukmo_seamless", value: 22)], .temperatureMax, leadHours: 12)
        precondition(near(spread.value, 20) && near(spread.stdDev, (8.0 / 3).squareRoot()) && spread.predictability == 0
            && spread.min == 18 && spread.max == 22 && spread.contributors.count == 3)
        // One model alone is thin: a third.
        let alone = Consensus.of([ModelValue(id: "ecmwf_ifs", value: 5)], .temperatureMin, leadHours: 0)
        precondition(near(alone.predictability, 1.0 / 3))
        // Weather codes: the weighted mode; a tie goes to the code seen first.
        let codes = Consensus.of([ModelValue(id: "ecmwf_ifs", value: 3), ModelValue(id: "gfs_seamless", value: 61),
                                  ModelValue(id: "ukmo_seamless", value: 61)], .weatherCode, leadHours: 0)
        precondition(codes.value == 61 && codes.stdDev == 0 && near(codes.predictability, 2.0 / 3))
        let tie = Consensus.of([ModelValue(id: "ecmwf_ifs", value: 3), ModelValue(id: "gfs_seamless", value: 61)],
                               .weatherCode, leadHours: 0)
        precondition(tie.value == 3)
        precondition(WeatherCodes.icon(61) == "🌦" && WeatherCodes.icon(60.6) == "🌦" && WeatherCodes.icon(4) == "•"
            && WeatherCodes.icon(nil) == "•" && WeatherCodes.code(2.4) == 2 && WeatherCodes.code(nil) == nil)
    }

    // MARK: Open-Meteo

    static func openMeteo() {
        let daily = OpenMeteo.dailyURL(latitude: 48.137, longitude: 11.575).absoluteString
        precondition(daily.hasPrefix("https://api.open-meteo.com/v1/forecast?latitude=48.137&longitude=11.575&daily=weather_code,"))
        precondition(daily.contains("models=ecmwf_ifs,gfs_seamless,") && daily.contains("&forecast_days=7&timezone=auto&wind_speed_unit=kmh"))
        let hourly = OpenMeteo.hourlyURL(latitude: 48.137, longitude: 11.575, variable: "precipitation").absoluteString
        precondition(hourly.contains("hourly=precipitation&models=") && !hourly.contains("wind_speed_unit"))
        precondition(OpenMeteo.hourlyKey(latitude: 48.1374, longitude: 11.5751, variable: "precipitation", models: ["a", "b"])
            == "48.137|11.575|precipitation|7|a,b")
        precondition(OpenMeteo.failure(status: 429, body: Data("Too many".utf8)).message == "open-meteo 429: Too many")

        // Times are the point's own: 00:00 at UTC+2 is 22:00 UTC the day before.
        precondition(OpenMeteo.instant("2026-10-20T00:00", utcOffset: 7200) == Date(timeIntervalSince1970: 1792454400 - 7200))
        precondition(OpenMeteo.instant("2026-10-20", utcOffset: 0) == Date(timeIntervalSince1970: 1792454400))
        precondition(OpenMeteo.instant("garbage", utcOffset: 0) == nil)

        let dailyBody = Data("""
        {"latitude":48.14,"longitude":11.58,"utc_offset_seconds":7200,"timezone":"Europe/Berlin",
         "daily":{"time":["2026-10-20","2026-10-21"],
          "temperature_2m_max_ecmwf_ifs":[15.2,null],"temperature_2m_max_gfs_seamless":[16,17],
          "temperature_2m_max_ukmo_seamless":[null,null],"weather_code_ecmwf_ifs":[3,61]}}
        """.utf8)
        let forecast = OpenMeteo.forecast(dailyBody)!
        precondition(forecast.days.count == 2 && forecast.utcOffset == 7200)
        precondition(forecast.respondingModels == ["ecmwf_ifs", "gfs_seamless"])
        precondition(forecast.days[0].values[.temperatureMax] == [ModelValue(id: "ecmwf_ifs", value: 15.2),
                                                                  ModelValue(id: "gfs_seamless", value: 16)])
        precondition(forecast.days[1].values[.temperatureMax] == [ModelValue(id: "gfs_seamless", value: 17)])
        precondition(forecast.days[1].values[.precipitationSum] == [])
        // Noon at the point, from now.
        precondition(OpenMeteo.leadHours(date: "2026-10-20", utcOffset: 7200, now: Date(timeIntervalSince1970: 1792454400))
            == 10)
        precondition(OpenMeteo.leadHours(date: "2026-10-19", utcOffset: 0, now: Date(timeIntervalSince1970: 1792454400)) == 0)

        let hourlyBody = Data("""
        {"utc_offset_seconds":3600,"hourly_units":{"precipitation_ecmwf_ifs":"mm"},
         "hourly":{"time":["2026-10-20T00:00","2026-10-20T01:00"],"precipitation_ecmwf_ifs":[0,0.4],
          "precipitation_gfs_seamless":[null,null],"precipitation_icon_d2":[null,1.2]}}
        """.utf8)
        let series = OpenMeteo.hourly(hourlyBody, variable: "precipitation")!
        precondition(series.ids == ["ecmwf_ifs", "icon_d2"] && series.units == "mm" && series.utcOffset == 3600)
        precondition(series.times == [Date(timeIntervalSince1970: 1792454400 - 3600), Date(timeIntervalSince1970: 1792454400)])
        precondition(series.series["icon_d2"]! == [nil, 1.2])
        precondition(OpenMeteo.hourly(Data("{}".utf8), variable: "precipitation") == nil)
    }

    // MARK: Outlook (core's outlook.test.ts)

    static let hour: TimeInterval = 3600
    static let t0 = Date(timeIntervalSince1970: 1790467200) // 2026-09-27 00:00 UTC

    static func series(_ rows: [String: [Double?]]) -> OpenMeteo.HourlySeries {
        let length = rows.values.map(\.count).max() ?? 0
        let ids = rows.keys.sorted()
        return OpenMeteo.HourlySeries(times: (0 ..< length).map { t0.addingTimeInterval(Double($0) * hour) }, ids: ids,
                                      series: rows, units: "mm", utcOffset: 0)
    }

    static func outlook() {
        let flat = series(["a": Array(repeating: 0, count: 48)])
        precondition(Outlook.stepAt(flat.times, t0.addingTimeInterval(9.5 * hour)) == 9)
        precondition(Outlook.stepAt(flat.times, t0.addingTimeInterval(-hour)) == 0)
        precondition(Outlook.stepAt(flat.times, t0.addingTimeInterval(100 * hour)) == 47)
        precondition(Outlook.stepAt([], t0) == 0)

        let env = Outlook.envelope(series(["a": [10, nil], "b": [30, nil], "c": [20, 5]]), from: 0, steps: 2)
        precondition(env.min == [10, 5] && env.mid == [20, 5] && env.max == [30, 5] && env.count == [3, 1])
        precondition(Outlook.quantile([1, 2, 3, 4], 0.5) == 2.5 && Outlook.quantile([7], 0.5) == 7)

        var wet = [Double?](repeating: 0, count: 48)
        wet[20] = 1.5
        let s = series(["a": wet, "b": wet, "c": Array(repeating: 0, count: 48)])
        precondition(Outlook.rainIn(s, from: 0, hours: 24) != nil)
        precondition(Outlook.rainIn(s, from: 0, hours: 20) == nil)
        precondition(Outlook.rainIn(s, from: 21, hours: 24) == nil)
        // One wet model among dry ones is disagreement, not rain.
        precondition(Outlook.rainIn(series(["a": Array(repeating: 4, count: 24), "b": Array(repeating: 0, count: 24),
                                            "c": Array(repeating: 0, count: 24)]), from: 0, hours: 24) == nil)

        var week = [Double?](repeating: 0, count: 168)
        week[5] = 0.3
        week[30] = 2
        let w = series(["a": week, "b": week, "c": Array(repeating: 0, count: 168)])
        precondition(Outlook.rainIn(w, from: 0, hours: 168) == 5)
        precondition(Outlook.rainIn(w, from: 3, hours: 168) == 2)
        precondition(Outlook.rainIn(w, from: 6, hours: 168) == 24)
        precondition(Outlook.rainIn(w, from: 5, hours: 168) == 0)
        let drizzle = [Double?](repeating: 0.1, count: 168)
        precondition(Outlook.rainIn(series(["a": drizzle, "b": drizzle]), from: 0, hours: 168) == nil)
        precondition(Outlook.rainIn(series(["a": Array(repeating: 4, count: 168), "b": drizzle, "c": drizzle]), from: 0, hours: 168) == nil)

        // daysAhead counts calendar days, not 24-hour spans, across DST too.
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
            berlin.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        let evening = local(2026, 10, 6, 23)
        precondition(Outlook.daysAhead(local(2026, 10, 7, 6), evening, calendar: berlin) == 1)
        precondition(Outlook.daysAhead(local(2026, 10, 6, 23, 30), evening, calendar: berlin) == 0)
        precondition(Outlook.daysAhead(local(2026, 10, 9, 0, 30), evening, calendar: berlin) == 3)
        precondition(Outlook.daysAhead(local(2026, 10, 26, 12), local(2026, 10, 24, 12), calendar: berlin) == 2)

        // The strip's title and range.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        precondition(Outlook.strip(nil, now: t0).title == .asking)
        let dry = Outlook.strip(series(["a": Array(repeating: 0, count: 168), "b": Array(repeating: 0, count: 168)]), now: t0,
                                calendar: utc)
        precondition(dry.title == .dryWeek && dry.hours == 168 && dry.from == 0)
        let soon = Outlook.strip(w, now: t0, calendar: utc)
        precondition(soon.title == .hours(5) && soon.hours == 24)
        var later = [Double?](repeating: 0, count: 168)
        later[30] = 1 // 2026-09-28 06:00, a Monday
        let tomorrow = Outlook.strip(series(["a": later, "b": later]), now: t0, calendar: utc)
        precondition(tomorrow.title == .tomorrow && tomorrow.hours == 168)
        var midweek = [Double?](repeating: 0, count: 168)
        midweek[80] = 1 // 2026-09-30 08:00, a Wednesday
        precondition(Outlook.strip(series(["a": midweek, "b": midweek]), now: t0, calendar: utc).title == .weekday(3))
        var lastDay = [Double?](repeating: 0, count: 170)
        lastDay[168] = 1 // 2026-10-04 00:00, seven days on from an hour past midnight
        let weekOn = Outlook.strip(series(["a": lastDay, "b": lastDay]), now: t0.addingTimeInterval(1.5 * hour), calendar: utc)
        precondition(weekOn.title == .days(7) && weekOn.from == 1)
        precondition(Outlook.Title.weekday(3).arguments == ["day": "3"] && Outlook.Title.hours(0).key == "dry_outlook_title_hours")

        // The titles' ICU, as core's strings carry it.
        let hours = "{hours, plural, =0 {Rain Likely Within the Hour} one {Rain Likely in # Hour} other {Rain Likely in # Hours}}"
        precondition(ICUMessage.format(hours, ["hours": "0"], language: "en") == "Rain Likely Within the Hour")
        precondition(ICUMessage.format(hours, ["hours": "1"], language: "en") == "Rain Likely in 1 Hour")
        precondition(ICUMessage.format(hours, ["hours": "5"], language: "en") == "Rain Likely in 5 Hours")
        let weekday = "{day, select, 0 {Rain Likely on Sunday} 3 {Rain Likely on Wednesday} other {Rain Likely This Week}}"
        precondition(ICUMessage.format(weekday, ["day": "3"], language: "en") == "Rain Likely on Wednesday")
    }

    static func axes() {
        // Over a day: every sixth hour; over a week: midnights.
        let times = (0 ..< 48).map { t0.addingTimeInterval(Double($0) * hour) }
        let utc = TimeZone(identifier: "UTC")!
        precondition(SpreadAxis.xMarks(Array(times.prefix(24)), steps: 24, timeZone: utc).map(\.index) == [0, 6, 12, 18])
        precondition(SpreadAxis.xMarks(times, steps: 49, timeZone: utc).map(\.index) == [0, 24])
        // In the point's own zone: at UTC+2 midnight is index 22.
        precondition(SpreadAxis.xMarks(times, steps: 49, timeZone: TimeZone(secondsFromGMT: 7200)!).map(\.index) == [22, 46])
        // Rainfall under the soft ceiling: 0–6 in 3s on the strip, 2s in the panel.
        precondition(SpreadAxis.yTicks(low: 0, high: 0.4, compact: true, fromZero: true, suggestedMax: 6) == [0, 3, 6])
        precondition(SpreadAxis.yTicks(low: 0, high: 6, compact: false, fromZero: true, suggestedMax: 6) == [0, 2, 4, 6])
        // Past it, Chart.js's nice steps.
        precondition(SpreadAxis.yTicks(low: 0, high: 13, compact: false, fromZero: true, suggestedMax: 6) == [0, 5, 10, 15])
        precondition(SpreadAxis.yTicks(low: 3.2, high: 17.8, compact: false, fromZero: false, suggestedMax: nil) == [0, 5, 10, 15, 20])
        precondition(SpreadAxis.niceNum(0.3) == 0.5 && SpreadAxis.niceNum(1) == 1 && SpreadAxis.niceNum(13) == 20)
    }

    // MARK: Lightning (core's lightningChart.test.ts and the palette)

    static func lightning() {
        precondition(LightningRules.colors.count == 121)
        precondition(LightningRules.index(minutes: 0) == 0 && LightningRules.index(minutes: 1) == 21)
        precondition(LightningRules.index(minutes: 2) == 32 && LightningRules.index(minutes: 30) == 60)
        precondition(LightningRules.index(minutes: 90) == 120 && LightningRules.index(minutes: 120) == 120)
        precondition(LightningRules.index(minutes: 120.1) == nil && LightningRules.index(minutes: -5) == 0)
        precondition(LightningRules.cross(ageMilliseconds: 0) == (0xFFFFCC, 120))
        precondition(LightningRules.cross(ageMilliseconds: 10 * 60_000).rgb == 0xFEBF5A)
        precondition(LightningRules.cross(ageMilliseconds: 30 * 60_000) == (0xFD8C3C, 90))
        precondition(LightningRules.cross(ageMilliseconds: 60 * 60_000).rgb == 0xE2191C)
        precondition(LightningRules.cross(ageMilliseconds: 95 * 60_000).rgb == 0x7E0025)
        precondition(LightningRules.cross(ageMilliseconds: 121 * 60_000) == (0xAAAAAA, 0))

        precondition(LightningRules.barColors.count == 30 && LightningRules.barColors.first == 0xFD8C3C
            && LightningRules.barColors[28] == 0xFED470 && LightningRules.barColors.last == 0xFFE590)
        precondition(LightningRules.yTickLabel(224, peak: 224) == "224" && LightningRules.yTickLabel(0, peak: 224) == "0")
        precondition(LightningRules.yTickLabel(100, peak: 224) == "" && LightningRules.yTickLabel(200, peak: 224) == "")
        let heights = LightningRules.skeletonHeights(30)
        precondition(heights.count == 30 && near(heights[0], 34) && near(heights[1], 58.0, 0.06) && near(heights[29], 60.5, 0.06))

        precondition(LightningRules.statsRing(minLon: 5, minLat: 45, maxLon: 16, maxLat: 55)
            == #"{"coordinates":[[5,45],[5,55],[16,55],[16,45],[5,45]]}"#)
        precondition(LightningRules.statsRing(minLon: -200, minLat: 45.5, maxLon: 16.25, maxLat: 55)
            == #"{"coordinates":[[-180,45.5],[-180,55],[16.25,55],[16.25,45.5],[-180,45.5]]}"#)
        precondition(LightningRules.bins(Data(#"{"time":1,"bins":[\#((0 ..< 30).map(String.init).joined(separator: ","))],"bin_size_min":1}"#.utf8))
            == Array(0 ..< 30))
        precondition(LightningRules.bins(Data(#"{"bins":[1,2]}"#.utf8)) == nil)

        let layer = LightningRules.Layer.decode(Data(#"{"processed_time":1792455848,"tile_id":"3f5d","most_recent_strike":1792455795,"num_strikes":65936}"#.utf8))
        precondition(layer?.tileId == "3f5d" && layer?.mostRecentStrike == 1792455795)
        let now = Date(timeIntervalSince1970: 1792456000)
        precondition(LightningRules.baseline(mostRecentStrike: 1792455795, now: now) == 1792455795)
        precondition(LightningRules.baseline(mostRecentStrike: 1792400000, now: now) == 1792456000 - 3480)

        // Strikes in milliseconds: the same strike once, evicted by the baseline.
        var book = LightningRules.StrikeBook()
        precondition(book.add([.init(x: 1, y: 2, milliseconds: 1792456185141.3), .init(x: 1, y: 2, milliseconds: 1792456185141.3)]))
        precondition(book.count == 1 && !book.add([.init(x: 1, y: 2, milliseconds: 1792456185141)]))
        book.add([.init(x: 3, y: 4, milliseconds: 1792456000000)])
        book.setBaseline(seconds: 1792456100)
        precondition(book.count == 1)
        // Older than the baseline is the tile set's.
        precondition(!book.add([.init(x: 5, y: 6, milliseconds: 1792456099999)]))
        book.prune(now: Date(timeIntervalSince1970: 1792456185 + 121 * 60))
        precondition(book.count == 0)
        precondition(LightningRules.backfill(Data(#"{"baseline":1,"strikes":[{"lat":5050358.86,"lon":460969.33,"time_wall":1792456185141}]}"#.utf8))
            == [.init(x: 460969.33, y: 5050358.86, milliseconds: 1792456185141)])
        precondition(LightningRules.live(Data(#"{"lat":1,"lon":2,"time":1792456185141.25}"#.utf8))?.milliseconds == 1792456185141.25)

        // NOAA: the tile's EPSG:3857 box; nothing asked outside the US.
        let noaa = LightningRules.noaaURL(z: 4, x: 3, y: 5)!.absoluteString
        precondition(noaa.contains("BBOX=-12523442.714243,5009377.085697,-10018754.171395,7514065.628546"), noaa)
        precondition(LightningRules.noaaCovers(z: 4, x: 3, y: 5) && !LightningRules.noaaCovers(z: 4, x: 8, y: 5))
    }

    // MARK: Precipitation types (core's hgClasses.test.ts)

    static func precipTypes() {
        precondition(PrecipTypes.lut[0] == 0)
        let classes = (1 ... 7).map { PrecipTypes.lut[$0] }
        precondition(classes.allSatisfy { $0 >> 24 == 0xFF } && Set(classes).count == 7)
        // Hail red, graupel orange; R, G, B, A in memory order.
        precondition(PrecipTypes.lut[7] == 0xFF0000FF && PrecipTypes.lut[6] == 0xFF0099FF && PrecipTypes.lut[3] == 0xFFFF0000)
        precondition(PrecipTypes.lut[8] == 0 && PrecipTypes.lut[255] == 0)
        precondition(PrecipTypes.legend.map(\.key) == ["hail", "graupel", "sleet", "snow", "rain", "drizzle", "n/a"])
        precondition(PrecipTypes.segment(0, of: 7) == 0 ... 14 && PrecipTypes.segment(6, of: 7) == 86 ... 100)
        let image = PrecipTypes.colour(width: 2, height: 2, pixels: [0, 3, 7, 9])
        precondition(image?.width == 2)
        precondition(PrecipTypes.colour(width: 2, height: 1, pixels: [0, 200]) == nil)
        let frame = PrecipTypes.Frame.decode(Data(#"{"tile_id":"a","upstream_time":1,"processed_time":2,"values":{"tile_id":"b","encoding":"hg-class-u8"}}"#.utf8))!
        precondition(frame.tilesId == "b" && frame.classBytes && frame.processedTime == 2)
        let legacy = PrecipTypes.Frame.decode(Data(#"{"tile_id":"a","processed_time":2}"#.utf8))!
        precondition(legacy.tilesId == "a" && !legacy.classBytes)
        precondition(PrecipTypes.tilePath("b", z: 5, x: 16, y: 10) == "meteoradar/b/5/16/21.png")
        precondition(PrecipTypes.freshness(age: 0) == 100 && PrecipTypes.freshness(age: 150) == 50 && PrecipTypes.freshness(age: 900) == 0)
        precondition(PrecipTypes.lastUpdated("3 minutes ago", prefix: "Last updated") == "Last updated 3 minutes ago")
        precondition(PrecipTypes.lastUpdated("about 22 hours ago, ok", prefix: "Last updated") == "about 22 hours ago, ok")
    }
}

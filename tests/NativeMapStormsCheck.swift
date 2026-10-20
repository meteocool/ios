import Foundation

/// Checks the native map's storm rules (`meteocool/NativeMap/Storms`) with
/// core's own tests, one for one: `scripts/tests/stormMarks.test.ts`,
/// `stormSelection.test.ts`, `stormStore.test.ts`, `cellKnownVolume.test.ts`,
/// `cellSelection.test.ts`, `cellPlacement.test.ts`, `cellRecency.test.ts`,
/// `cellStatus.test.ts`, `cellLineage.test.ts`, `cellPulse.test.ts`,
/// `timeTicks.test.ts` and `swipeAway.test.ts`, then the native extras.
@main
struct NativeMapStormsCheck {
    static var count = 0
    /// The test running, which a failed precondition's trace names.
    nonisolated(unsafe) static var current = ""

    /// One of core's tests, by its name.
    static func test(_ name: String, _ body: () -> Void) {
        current = name
        body()
        count += 1
    }

    static func main() {
        stormMarks()
        stormSelection()
        stormStore()
        cellKnownVolume()
        cellSelection()
        cellPlacement()
        cellRecency()
        cellStatus()
        cellLineage()
        cellPulse()
        timeTicks()
        swipeAway()
        decoding()
        extras()
        print("NativeMapStormsCheck: \(count) checks passed")
    }

    // MARK: - Fixtures (core's `scripts/tests/stormFixtures.ts`)

    static let T0 = StormTime.ms("2026-10-12T14:00:00Z")
    static func at(_ minutes: Double) -> String { StormTime.iso(T0 + minutes * 60_000) }
    static func sid(_ letter: String) -> String { String(("01JA" + String(repeating: letter, count: 22)).prefix(26)) }

    static func storm(_ id: String, _ change: (inout StormProperties) -> Void = { _ in },
                      path: [[Double]] = [[10, 50], [10.1, 50.05]]) -> Storm {
        let points = path.map { LonLat($0[0], $0[1]) }
        let last = points[points.count - 1]
        var p = StormProperties(id: id, bornAt: at(-60), lastSeen: at(0), status: "active",
                                bbox: Bounds(west: 10, south: 50, east: 10.1, north: 50.05),
                                path: points.count > 1 ? .line(points) : .point(last))
        p.severity = 1
        change(&p)
        return Storm(id: id, geometry: last, properties: p)
    }

    static func cell(_ code: String, _ change: (inout TrackProperties) -> Void = { _ in }) -> TrackProperties {
        var c = TrackProperties(code: code, firstSeen: at(-30), lastSeen: at(0))
        c.nSteps = 2
        c.active = true
        c.maxSeverity = 2
        c.series = [
            CellStep(t: at(-5), lon: 10, lat: 50, severity: 2, headingDeg: 80),
            CellStep(t: at(0), lon: 10.1, lat: 50.05, severity: 2, headingDeg: 90),
        ]
        change(&c)
        return c
    }

    static func volume(_ path: String, _ change: (inout RadarVolume) -> Void = { _ in }) -> RadarVolume {
        var v = RadarVolume(path: path, coverage: 1, code: path, lon: 10.1, lat: 50.05, referenceTime: at(0))
        change(&v)
        return v
    }

    static func feature(_ id: String, _ minutes: Double, _ change: (inout TrackerFeature) -> Void = { _ in }) -> TrackerFeature {
        var f = TrackerFeature(id: id, kind: "core", validAt: at(minutes), parent: nil, centroid: LonLat(10.1, 50.05),
                               peak: LonLat(10.1, 50.05), peakDbz: 50, areaKm2: 20,
                               outline: [[LonLat(10, 50), LonLat(10.2, 50), LonLat(10.2, 50.1), LonLat(10, 50)]])
        change(&f)
        return f
    }

    static func trackerTrack(_ id: String, _ features: [TrackerFeature], _ change: (inout TrackerTrack) -> Void = { _ in }) -> TrackerTrack {
        var t = TrackerTrack(id: id, product: "meteocool/tracker", domain: "de", kind: "core",
                             firstSeen: features.first?.validAt ?? at(-30), lastSeen: features.last?.validAt ?? at(0),
                             active: true, maxPeakDbz: 55, bbox: nil, path: .point(LonLat(10.1, 50.05)),
                             nFeatures: features.count, features: features)
        change(&t)
        return t
    }

    static func detail(_ of: Storm, konrad3d: [TrackProperties] = [], tracks: [TrackerTrack] = []) -> StormDetail {
        StormDetail(storm: of, konrad3d: konrad3d, tracks: tracks)
    }

    /// Names the message and what was put into it, as core's tests do.
    static let t: StormTranslate = { key, values in
        values.isEmpty ? key : "\(key)(" + values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: ",") + ")"
    }

    /// core's real messages for a language, from the app's `Core.strings`.
    static func catalogue(_ lang: String) -> StormTranslate {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("meteocool/\(lang).lproj/Core.strings")
        guard let data = try? Data(contentsOf: url),
              let messages = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
            preconditionFailure("no \(url.path)")
        }
        return { key, values in
            guard let message = messages[key] else { preconditionFailure("\(lang) has no \(key)") }
            return ICUMessage.format(message, values, language: lang)
        }
    }

    static func kinds(_ marks: [StormMark], _ id: String) -> [String] {
        marks.filter { $0.storm == id }.map(\.kind.rawValue)
    }

    // MARK: - stormMarks.test.ts

    static func stormMarks() {
        let A = sid("A"), B = sid("B")
        let now = T0
        func draw(_ storms: [Storm], now: Double = T0, selection: StormSelection? = nil, at: Double? = nil) -> StormDrawingResult {
            StormDrawing.drawStorms(storms, now: now, reference: now, selection: selection, at: at)
        }
        let forecast = [
            ForecastPoint(t: at(15), lon: 10.3, lat: 50.1, majorKm: 5, minorKm: 3, angleDeg: 90),
            ForecastPoint(t: at(30), lon: 10.5, lat: 50.15, majorKm: 8, minorKm: 5, angleDeg: 90),
        ]

        test("an active storm draws its path and its position, and is ringed while live") {
            let d = draw([storm(A)])
            precondition(kinds(d.marks, A) == ["path", "position"])
            precondition(d.marks.first { $0.kind == .position }?.live == true)
            precondition(d.pings.map(\.storm) == [A])
        }
        test("a ring carries how long its storm has been tracked, first detection to last") {
            let d = draw([storm(A) { $0.bornAt = at(-25); $0.lastSeen = at(-5) }])
            precondition(d.pings[0].historyMinutes == 20)
        }
        test("a storm drawn on an earlier frame has been tracked only until then") {
            let then = T0 - 50 * 60_000
            let d = draw([storm(A) { $0.bornAt = at(-60); $0.lastSeen = at(0) }], now: then, at: then)
            precondition(d.pings[0].historyMinutes == 10)
        }
        test("a storm seen once has no path, only a position") {
            precondition(kinds(draw([storm(A, path: [[10, 50]])]).marks, A) == ["position"])
        }
        test("a storm that ended a while ago is not drawn, unless it is the selected one") {
            let ended = storm(A) { $0.status = "ended"; $0.lastSeen = at(-45) }
            precondition(!StormDrawing.isDrawn(ended, reference: now, selected: nil))
            precondition(StormDrawing.isDrawn(ended, reference: now, selected: A))
            precondition(draw([ended]).marks.isEmpty)
        }
        test("a storm not seen for a few minutes is drawn but no longer ringed") {
            let d = draw([storm(A) { $0.lastSeen = at(-12) }])
            precondition(d.marks.first { $0.kind == .position }?.live == false)
            precondition(d.pings.isEmpty)
        }
        test("a merged storm keeps its path, joined to the one it merged into, and gives up its position") {
            let merged = storm(B, { $0.status = "merged"; $0.mergedInto = A; $0.lastSeen = at(-5) }, path: [[9.8, 49.9], [9.95, 50]])
            let survivor = storm(A, path: [[10, 50], [10.1, 50.05]])
            let d = draw([merged, survivor])
            precondition(kinds(d.marks, B) == ["path"])
            precondition(d.pings.map(\.storm) == [A])
            precondition(d.links.count == 1 && d.links[0].storm == A && d.links[0].fromStorm == B)
            precondition(d.links[0].geometry == .line([LonLat(9.95, 50), LonLat(10, 50)]))
        }
        test("a storm merged into one not on the map keeps its position and draws no join") {
            let d = draw([storm(B) { $0.status = "merged"; $0.mergedInto = A; $0.lastSeen = at(-5) }])
            precondition(kinds(d.marks, B) == ["path", "position"])
            precondition(d.links.isEmpty)
        }
        test("a join meets the storm it merged into at the vertex nearest its end") {
            precondition(StormDrawing.nearestOn([LonLat(0, 0), LonLat(1, 0), LonLat(2, 0)], LonLat(1.2, 0.1)) == LonLat(1, 0))
        }
        test("a branch of a split is joined to where the storm it split from was when it branched off") {
            let parent = storm(A, { $0.bornAt = at(-60) }, path: [[10, 50], [10.1, 50], [10.2, 50], [10.3, 50]])
            let branch = storm(B, { $0.bornAt = at(-40); $0.splitFrom = A }, path: [[10.12, 50.05], [10.2, 50.1]])
            let d = draw([parent, branch])
            precondition(kinds(d.marks, B) == ["path", "position"])
            precondition(d.links.count == 1 && d.links[0].storm == B && d.links[0].fromStorm == A)
            precondition(d.links[0].geometry == .line([LonLat(10.1, 50), LonLat(10.12, 50.05)]))
        }
        test("a branch whose parent is not on the map, or not yet split off, draws no join") {
            let parent = storm(A, { $0.bornAt = at(-60) }, path: [[10, 50], [10.3, 50]])
            let branch = storm(B, { $0.bornAt = at(-40); $0.splitFrom = A }, path: [[10.12, 50.05], [10.2, 50.1]])
            precondition(draw([branch]).links.isEmpty)
            precondition(draw([parent, branch], now: T0 - 50 * 60_000, at: T0 - 50 * 60_000).links.isEmpty)
        }
        test("the selected KONRAD3D storm draws its forecast and ellipses, with labels on the far end") {
            let of = storm(A) { $0.primaryProduct = "dwd/konrad3d"; $0.primaryTrack = "C1" }
            let selection = StormSelect.withDetail(StormSelect.fromStorm(of), detail(of, konrad3d: [cell("C1") { $0.forecast = forecast }]))
            let d = draw([of], selection: selection)
            precondition(kinds(d.marks, A) == ["path", "position", "forecast", "ellipse", "forecast", "ellipse"])
            let ellipse = d.marks.first { $0.kind == .ellipse }!
            precondition(ellipse.leadMinutes == 15)
            precondition(ellipse.forecastAt == T0 + 15 * 60_000)
            precondition(ellipse.tip!.lon > 10.3, "the label sits on the leading edge, east of the centre")
        }
        test("an unselected storm draws no forecast") {
            let of = storm(A) { $0.primaryProduct = "dwd/konrad3d"; $0.primaryTrack = "C1" }
            let other = storm(B)
            let selection = StormSelect.withDetail(StormSelect.fromStorm(other), detail(other))
            precondition(kinds(draw([of, other], selection: selection).marks, A) == ["path", "position"])
        }
        test("outside Germany a storm has no forecast, whatever cell it is shown with") {
            let of = storm(A) { $0.primaryProduct = "meteocool/tracker"; $0.primaryDomain = "fr" }
            var selection = StormSelect.fromStorm(of)
            selection.cell = cell("C1") { $0.forecast = forecast }
            precondition(StormDrawing.forecastCell(selection) == nil)
            precondition(kinds(draw([of], selection: selection).marks, A) == ["path", "position"])
        }
        test("a cell whose storm is not found yet still draws its forecast as the selection") {
            let selection = StormSelect.withCell(nil, cell("C1") { $0.forecast = forecast })
            precondition(StormDrawing.selectedMark(selection) == "cell:C1")
            precondition(draw([], selection: selection).marks.map(\.kind.rawValue) == ["forecast", "ellipse", "forecast", "ellipse"])
        }
        test("a cell no longer detected draws no forecast") {
            precondition(StormDrawing.forecastCell(StormSelect.withCell(nil, cell("C1") { $0.forecast = forecast; $0.active = false })) == nil)
        }
        test("the selected storm is drawn from its own copy when the answer leaves it out") {
            let selection = StormSelect.fromStorm(storm(A))
            precondition(kinds(draw([storm(B)], selection: selection).marks, A) == ["path", "position"])
        }
        test("the selected storm's outline is drawn, and only its") {
            let ring = [LonLat(10, 50), LonLat(10.2, 50), LonLat(10.2, 50.1), LonLat(10, 50)]
            let of = storm(A) { $0.primaryProduct = "dwd/konrad3d"; $0.primaryTrack = "C1" }
            let selection = StormSelect.withDetail(StormSelect.fromStorm(of), detail(of, konrad3d: [cell("C1") { $0.polygon = ring }]))
            precondition(draw([of, storm(B)], selection: selection).marks.filter { $0.kind == .outline }.map(\.storm) == [A])
        }
        test("hail and rotation ride on every mark of the storm, for the badge") {
            precondition(draw([storm(A) { $0.hail = true; $0.meso = true }]).marks.allSatisfy { $0.hail && $0.meso })
        }
        test("an earlier frame does not show a storm not yet born") {
            precondition(StormDrawing.stormAsOf(storm(A) { $0.bornAt = at(-10) }, T0 - 20 * 60_000) == nil)
        }
        test("an earlier frame cuts a storm still going back in proportion, active and unmerged") {
            let merged = storm(A, { $0.bornAt = at(-40); $0.lastSeen = at(0); $0.status = "merged"; $0.mergedInto = B },
                               path: [[0, 0], [1, 0], [2, 0], [3, 0], [4, 0]])
            let then = StormDrawing.stormAsOf(merged, T0 - 20 * 60_000)!
            precondition(then.properties.path == .line([LonLat(0, 0), LonLat(1, 0), LonLat(2, 0)]))
            precondition(then.geometry == LonLat(2, 0))
            precondition(then.properties.status == "active" && then.properties.mergedInto == nil)
        }
        test("an earlier frame shortly after a storm's last sighting shows it still active") {
            let ended = storm(A) { $0.bornAt = at(-60); $0.lastSeen = at(-30); $0.status = "ended" }
            precondition(StormDrawing.stormAsOf(ended, T0 - 25 * 60_000)!.properties.status == "active")
            precondition(StormDrawing.stormAsOf(ended, T0)!.properties.status == "ended")
        }
        test("an earlier frame draws no forecast, even for the selected storm") {
            let of = storm(A) { $0.primaryProduct = "dwd/konrad3d"; $0.primaryTrack = "C1"; $0.bornAt = at(-60) }
            let selection = StormSelect.withDetail(StormSelect.fromStorm(of), detail(of, konrad3d: [cell("C1") { $0.forecast = forecast }]))
            let then = T0 - 10 * 60_000
            precondition(!draw([of], now: then, selection: selection, at: then).marks.contains { $0.kind == .forecast || $0.kind == .ellipse })
        }
    }

    // MARK: - stormSelection.test.ts

    static func stormSelection() {
        let A = sid("A"), B = sid("B")
        func claimed(_ id: String, _ code: String) -> Storm {
            storm(id) { $0.tracks = [StormTrackClaim(product: "dwd/konrad3d", domain: "de", track: code)] }
        }
        typealias S = StormSelect

        test("a storm tapped on the map is selected by its id, with nothing else known yet") {
            let s = S.fromStorm(storm(A))
            precondition(s.id == A && s.detail == nil && s.cell == nil && S.selectionKey(s) == "storm:\(A)")
        }
        test("a cell tapped with nothing open is a seed, with no storm yet") {
            let s = S.withCell(nil, cell("C1"))
            precondition(s.id == nil && s.cell?.code == "C1" && S.selectionKey(s) == "cell:C1" && S.lookupOf(s) == .cell("C1"))
        }
        test("walking to a cell the open storm claims stays in that storm") {
            let open = S.fromStorm(claimed(A, "C2"))
            let walked = S.withCell(open, cell("C2"))
            precondition(walked.id == A && walked.cell?.code == "C2" && walked.summary == open.summary)
        }
        test("walking to a cell the open storm does not claim starts over from that cell") {
            let walked = S.withCell(S.fromStorm(claimed(A, "C2")), cell("C9"))
            precondition(walked.id == nil && walked.summary == nil && walked.cell?.code == "C9")
        }
        test("a cell handed over again keeps the volume an earlier copy had") {
            let known = cell("C1") { $0.volume = CellVolume(path: "v1", coverage: 1) }
            let again = S.withCell(S.withCell(nil, known), cell("C1") { $0.volume = nil })
            precondition(again.cell?.volume?.path == "v1")
        }
        test("a box of sky with no storm open is a seed, looked up by the patch it names") {
            let s = S.withVolume(nil, volume("p/1") { $0.feature = "patch-7" })
            precondition(s.id == nil && S.selectionKey(s) == "cloud:p/1" && S.lookupOf(s) == .feature("patch-7"))
        }
        test("a box with no patch named cannot be looked up") {
            precondition(S.lookupOf(S.withVolume(nil, volume("p/1"))) == nil)
        }
        test("a box of the open storm's own patch stays in that storm") {
            let open = S.withDetail(S.fromStorm(storm(A)), detail(storm(A), tracks: [trackerTrack("t1", [feature("core-1", 0) { $0.parent = "patch-7" }])]))!
            let tapped = S.withVolume(open, volume("p/1") { $0.feature = "patch-7" })
            precondition(tapped.id == A && tapped.volume?.path == "p/1")
        }
        test("finding a seed's storm keeps what the seed was opened on") {
            let seed = S.withCell(nil, cell("C1"))
            let found = S.withStorm(seed, claimed(A, "C1"))
            precondition(found.id == A && found.cell?.code == "C1" && S.isResolution(seed, found))
        }
        test("a refresh of the open storm keeps its detail and cell") {
            let open = S.withDetail(S.fromStorm(claimed(A, "C1")), detail(claimed(A, "C1"), konrad3d: [cell("C1")]))!
            let refreshed = S.withStorm(open, claimed(A, "C1"))
            precondition(refreshed.detail == open.detail && refreshed.cell?.code == "C1")
        }
        test("another storm replaces the selection outright") {
            let open = S.withDetail(S.fromStorm(storm(A)), detail(storm(A)))!
            let other = S.withStorm(open, storm(B))
            precondition(other.id == B && other.detail == nil && !S.isResolution(open, other))
        }
        test("opening another seed is not a resolution of the first") {
            precondition(!S.isResolution(S.withCell(nil, cell("C1")), S.withStorm(S.withCell(nil, cell("C2")), storm(A))))
        }
        test("a detail shows the storm's primary KONRAD3D track") {
            let of = storm(A) { $0.primaryProduct = "dwd/konrad3d"; $0.primaryTrack = "C2" }
            let s = S.withDetail(S.fromStorm(of), detail(of, konrad3d: [cell("C1") { $0.lastSeen = at(5) }, cell("C2")]))!
            precondition(s.cell?.code == "C2")
        }
        test("with the tracker primary, the most recently seen KONRAD3D track is shown") {
            let of = storm(A) { $0.primaryProduct = "meteocool/tracker"; $0.primaryTrack = "t1" }
            let shown = S.primaryCell(detail(of, konrad3d: [cell("C1") { $0.lastSeen = at(-10) }, cell("C2") { $0.lastSeen = at(-2) }]))
            precondition(shown?.code == "C2")
        }
        test("a storm KONRAD3D does not track has no cell") {
            let of = storm(A) { $0.primaryProduct = "meteocool/tracker"; $0.primaryDomain = "fr" }
            precondition(S.withDetail(S.fromStorm(of), detail(of))!.cell == nil)
        }
        test("a detail keeps the cell walked to rather than going back to the primary one") {
            let of = storm(A) {
                $0.primaryProduct = "dwd/konrad3d"
                $0.primaryTrack = "C2"
                $0.tracks = [StormTrackClaim(product: "dwd/konrad3d", domain: "de", track: "C1"),
                             StormTrackClaim(product: "dwd/konrad3d", domain: "de", track: "C2")]
            }
            let walked = S.withCell(S.fromStorm(of), cell("C1"))
            let fetched = S.withDetail(walked, detail(of, konrad3d: [cell("C1") { $0.maxSeverity = 3 }, cell("C2")]))!
            precondition(fetched.cell?.code == "C1" && fetched.cell?.maxSeverity == 3)
        }
        test("a detail for a storm no longer selected changes nothing") {
            let open = S.fromStorm(storm(B))
            precondition(S.withDetail(open, detail(storm(A))) == open)
            precondition(S.withDetail(nil, detail(storm(A))) == nil)
        }
        test("a storm claims a cell by its tracks, its detail's tracks, or its detail's cells") {
            precondition(S.claimsCell(S.fromStorm(claimed(A, "C1")), "C1"))
            var byDetailTracks = S.byId(A)
            byDetailTracks.detail = detail(claimed(A, "C2"))
            precondition(S.claimsCell(byDetailTracks, "C2"))
            var viaDetail = S.fromStorm(storm(A))
            viaDetail.detail = detail(storm(A), konrad3d: [cell("C3")])
            precondition(S.claimsCell(viaDetail, "C3") && !S.claimsCell(viaDetail, "C4"))
        }
        test("a volume's patch is the storm's when one of its cores sits in it") {
            var s = S.fromStorm(storm(A))
            s.detail = detail(storm(A), tracks: [trackerTrack("t1", [feature("core-1", 0) { $0.parent = "patch-7" }])])
            precondition(S.holdsFeature(s, "patch-7") && S.holdsFeature(s, "core-1") && !S.holdsFeature(s, "patch-8"))
        }
        test("only DWD's class is named as a severity") {
            precondition(S.knowsSeverity(S.fromStorm(storm(A) { $0.primaryProduct = "dwd/konrad3d" })))
            precondition(!S.knowsSeverity(S.fromStorm(storm(A) { $0.primaryProduct = "meteocool/tracker" })))
            precondition(S.knowsSeverity(S.withCell(nil, cell("C1"))))
        }
        test("where a storm is: its centroid, else its cell, else its box") {
            precondition(S.positionOf(S.fromStorm(storm(A, path: [[9, 49], [9.5, 49.5]]))) == LonLat(9.5, 49.5))
            precondition(S.positionOf(S.withCell(nil, cell("C1"))) == LonLat(10.1, 50.05))
            precondition(S.positionOf(S.withVolume(nil, volume("p") { $0.lon = 7; $0.lat = 47 })) == LonLat(7, 47))
        }
        test("the slice starts along the cell's heading, else the storm's, else north") {
            precondition(S.headingOf(S.withCell(nil, cell("C1"))) == 90)
            precondition(S.headingOf(S.fromStorm(storm(A) { $0.headingDeg = 45 })) == 45)
            precondition(S.headingOf(S.withVolume(nil, volume("p"))) == nil)
        }
        test("the storm's box is the one cut from its newest patch nearest its centroid") {
            let of = storm(A, path: [[10, 50], [10.1, 50.05]])
            let s = S.withDetail(S.fromStorm(of), detail(of, tracks: [trackerTrack("t1", [
                feature("old", -5) { $0.parent = "patch-old" },
                feature("now", 0) { $0.parent = "patch-now" },
            ])]))!
            precondition(S.newestPatches(s) == ["patch-now"])
            let chosen = S.volumeOfStorm([
                volume("far") { $0.feature = "patch-now"; $0.lon = 10.4; $0.lat = 50.2 },
                volume("near") { $0.feature = "patch-now"; $0.lon = 10.11; $0.lat = 50.06 },
                volume("stale") { $0.feature = "patch-old"; $0.lon = 10.1; $0.lat = 50.05 },
                volume("coarse") { $0.feature = "patch-now"; $0.coarse = true; $0.lon = 10.1; $0.lat = 50.05 },
            ], s)
            precondition(chosen?.path == "near")
        }
        test("volumes that name no patch give a storm no box") {
            let of = storm(A)
            let s = S.withDetail(S.fromStorm(of), detail(of, tracks: [trackerTrack("t1", [feature("c", 0) { $0.parent = "p" }])]))!
            precondition(S.volumeOfStorm([volume("v")], s) == nil)
        }
        test("a tracker history is the primary track's features, one per frame, oldest first") {
            let of = storm(A) { $0.primaryProduct = "meteocool/tracker"; $0.primaryTrack = "t1" }
            let series = S.trackerSeries(detail(of, tracks: [
                trackerTrack("t0", [feature("x", -10) { $0.peakDbz = 70 }]),
                trackerTrack("t1", [
                    feature("b", -5) { $0.peakDbz = 52; $0.areaKm2 = 30 },
                    feature("a", -10) { $0.peakDbz = 48; $0.areaKm2 = 20 },
                    feature("b2", -5) { $0.peakDbz = 45; $0.areaKm2 = 5 },
                ]),
            ]))
            precondition(series == [S.StormStep(t: at(-10), peakDbz: 48, areaKm2: 20), S.StormStep(t: at(-5), peakDbz: 52, areaKm2: 30)])
        }
        test("a cell is found in its storm by the tracks each listed storm claims") {
            precondition(S.stormClaiming([storm(A), claimed(B, "C1")], "C1")?.properties.id == B)
            precondition(S.stormClaiming([storm(A)], "C1") == nil)
        }
        test("the storms worth searching for a box are the few nearest it") {
            let near = storm(A, path: [[10.1, 50.05]])
            let further = storm(B, path: [[10.3, 50.05]])
            let far = storm(sid("C"), path: [[12, 52]])
            let found = S.nearestStorms([far, further, near, near], LonLat(10.1, 50.05), withinKm: 40, count: 2)
            precondition(found.map(\.properties.id) == [A, B])
        }
        test("a storm named by id alone takes the map's copy when there is one") {
            precondition(S.byId(A, held: [storm(A)]).summary?.properties.id == A)
            precondition(S.byId(A).summary == nil && S.byId(A).id == A)
        }
        test("the storms that merged into one are found among those held") {
            let merged = storm(B) { $0.status = "merged"; $0.mergedInto = A }
            precondition(S.mergedInto([storm(A), merged], A).map(\.properties.id) == [B])
        }
        test("the outline is the KONRAD3D cell's where that track is primary, else the tracker's newest") {
            let ring = [LonLat(1, 1), LonLat(2, 1), LonLat(2, 2), LonLat(1, 1)]
            let k = storm(A) { $0.primaryProduct = "dwd/konrad3d"; $0.primaryTrack = "C1" }
            let konrad = S.withDetail(S.fromStorm(k), detail(k, konrad3d: [cell("C1") { $0.polygon = ring }]))!
            precondition(S.outlineOf(konrad) == ring)
            let ours = storm(A) { $0.primaryProduct = "meteocool/tracker"; $0.primaryTrack = "t1" }
            let tracker = S.withDetail(S.fromStorm(ours), detail(ours, tracks: [trackerTrack("t1", [feature("c", 0)])]))!
            precondition(S.outlineOf(tracker)?.count == 4)
            precondition(S.outlineOf(S.fromStorm(storm(A))) == nil)
        }
        test("a selection stays open on an earlier frame it had already appeared by") {
            func minute(_ m: Double) -> Double { T0 + m * 60_000 }
            let open = S.fromStorm(storm(A) { $0.bornAt = at(-60) })
            precondition(S.existedBy(open, minute(-30)) && S.existedBy(open, minute(-60)) && !S.existedBy(open, minute(-90)))
            let seed = S.withCell(nil, cell("C1") { $0.firstSeen = at(-20) })
            precondition(S.existedBy(seed, minute(-10)) && !S.existedBy(seed, minute(-25)))
            precondition(!S.existedBy(S.withVolume(nil, volume("v")), minute(0)))
        }
    }

    // MARK: - stormStore.test.ts (the store's rules: `StormStore` holds one selection)

    static func stormStore() {
        let A = sid("A")
        test("setting a cell with nothing open selects it as a seed of its storm") {
            let s = StormSelect.withCell(nil, cell("C1"))
            precondition(s.id == nil && s.cell?.code == "C1")
        }
        test("setting a cell the open storm claims walks within that storm") {
            let open = StormSelect.fromStorm(storm(A) { $0.tracks = [StormTrackClaim(product: "dwd/konrad3d", domain: "de", track: "C2")] })
            let s = StormSelect.withCell(open, cell("C2"))
            precondition(s.id == A && s.cell?.code == "C2")
        }
        test("setting null clears the whole selection") {
            let cleared: StormSelection? = nil
            precondition(StormSelect.selectionKey(cleared) == "")
        }
        test("a storm with no KONRAD3D track reads as no cell") {
            precondition(StormSelect.fromStorm(storm(A)).cell == nil)
        }
        test("a storm's status: merged and ended as the backend says, live until a quarter hour of silence") {
            precondition(StormRules.stormStatus("merged", ageMinutes: 0) == .merged)
            precondition(StormRules.stormStatus("ended", ageMinutes: 30) == .ended)
            precondition(StormRules.stormStatus("active", ageMinutes: 4) == .live)
            precondition(StormRules.stormStatus("active", ageMinutes: 15) == .stale)
            precondition(StormRules.statusLabel(.live, t) == "storm.status.live")
        }
    }

    // MARK: - cellKnownVolume.test.ts

    static func cellKnownVolume() {
        func vol(_ scan: String) -> CellVolume { CellVolume(path: "meteoradar/volumes/\(scan)/de-A.mcvx", coverage: 1) }
        func copy(_ code: String, _ v: CellVolume? = nil) -> TrackProperties {
            var c = TrackProperties(code: code, firstSeen: "", lastSeen: "")
            c.active = true
            c.volume = v
            return c
        }
        let known = vol("20261011T013000")
        test("a copy without a volume keeps the one already known for the storm") {
            precondition(StormSelect.withKnownVolume(copy("A"), copy("A", known)).volume == known)
        }
        test("a copy that has a volume keeps its own, the newer one") {
            let next = copy("A", vol("20261011T013500"))
            precondition(StormSelect.withKnownVolume(next, copy("A", known)) == next)
        }
        test("a copy with nothing known about the storm is left as it came") {
            precondition(StormSelect.withKnownVolume(copy("A")) == copy("A"))
            precondition(StormSelect.withKnownVolume(copy("A"), nil, nil) == copy("A"))
        }
        test("another storm's volume is never borrowed") {
            precondition(StormSelect.withKnownVolume(copy("A"), copy("B", known)).volume == nil)
        }
        test("a known copy without a volume does not hide a later one that has it") {
            precondition(StormSelect.withKnownVolume(copy("A"), copy("A"), copy("A", known)).volume == known)
        }
        test("the first known copy with a volume is the one kept") {
            precondition(StormSelect.withKnownVolume(copy("A"), copy("A", known), copy("A", vol("20261011T012500"))).volume == known)
        }
        test("the copy is not changed in place") {
            let next = copy("A")
            _ = StormSelect.withKnownVolume(next, copy("A", known))
            precondition(next.volume == nil)
        }
    }

    // MARK: - cellSelection.test.ts

    static func cellSelection() {
        typealias T = StormSelect.Tapped
        let none = T.none, drawn = T(code: "A", details: false), open = T(code: "A", details: true)
        func next(_ c: T, _ tapped: String?, _ two: Bool) -> T { StormSelect.nextSelection(c, tapped, twoStage: two) }
        test("a desktop tap opens the panel on the first one") { precondition(next(none, "A", false) == open) }
        test("a desktop tap on another cell moves the open panel to it") { precondition(next(open, "B", false) == T(code: "B", details: true)) }
        test("a phone's first tap draws the cell without opening the panel") { precondition(next(none, "A", true) == drawn) }
        test("a phone's second tap on the same cell opens it") { precondition(next(drawn, "A", true) == open) }
        test("a phone tap on a different cell starts that one over at the drawing") { precondition(next(open, "B", true) == T(code: "B", details: false)) }
        test("tapping the open cell again leaves the panel open") { precondition(next(open, "A", true) == open) }
        test("the map background clears everything, on either") {
            precondition(next(open, nil, true) == none && next(open, nil, false) == none && next(drawn, nil, true) == none)
        }
        test("closing on a phone keeps the forecast on the map") { precondition(StormSelect.afterClose(open, twoStage: true) == drawn) }
        test("closing anywhere else clears the selection") { precondition(StormSelect.afterClose(open, twoStage: false) == none) }
    }

    // MARK: - cellPlacement.test.ts

    static func cellPlacement() {
        let en = catalogue("en"), de = catalogue("de")
        func freising(_ direction: String?, _ km: Double = 18.4) -> CellPlacement {
            CellPlacement(place: "Freising", distanceKm: km, direction: direction, bearingDeg: direction == nil ? nil : 0, kind: "town")
        }
        func label(_ p: CellPlacement?, _ t: @escaping StormTranslate, _ style: StormRules.PlacementStyle = .long) -> String? {
            StormRules.placementLabel(p, t, style: style)
        }
        test("a cell with nothing to be named after has no name") {
            var blank = freising("N")
            blank.place = "  "
            precondition(label(nil, en) == nil && label(blank, en) == nil)
        }
        test("the long form carries the distance, in both languages") {
            precondition(label(freising("N"), en) == "18 km N of Freising")
            precondition(label(freising("NE"), de) == "18 km NO von Freising")
        }
        test("the short form drops the distance a graph node has no room for") {
            precondition(label(freising("N"), en, .short) == "N of Freising")
            precondition(label(freising("E"), de, .short) == "O von Freising")
        }
        test("a cell over its place gets no direction, at either length") {
            for style in [StormRules.PlacementStyle.long, .short] {
                precondition(label(freising(nil, 2.1), en, style) == "Over Freising")
                precondition(label(freising(nil, 2.1), de, style) == "Über Freising")
            }
        }
        test("distances are whole kilometres") {
            precondition(label(freising("S", 17.5), en) == "18 km S of Freising")
            precondition(label(freising("S", 6.04), en) == "6 km S of Freising")
        }
        test("the place keeps the name it arrived with") {
            var munich = freising("W")
            munich.place = "München"
            precondition(label(munich, en) == "18 km W of München")
        }
        test("every compass point the server can send is translated, in both languages") {
            let german = ["N": "N", "NE": "NO", "E": "O", "SE": "SO", "S": "S", "SW": "SW", "W": "W", "NW": "NW"]
            for (point, deName) in german {
                precondition(label(freising(point), en, .short) == "\(point) of Freising")
                precondition(label(freising(point), de, .short) == "\(deName) von Freising")
            }
        }
        test("a direction this client does not know is shown, not turned into 'over'") {
            precondition(label(freising("NNE"), en) == "18 km NNE of Freising")
        }
    }

    // MARK: - cellRecency.test.ts

    static func cellRecency() {
        let MIN = 60_000.0, now = 1_000 * 60_000.0
        test("age is measured from the detection to the clock") {
            precondition(StormRules.cellRecency(lastSeenMs: now - 4 * MIN, nowMs: now, radarFrameMs: nil).ageMinutes == 4)
        }
        test("a detection stamped ahead of the clock reads as current, not negative") {
            precondition(StormRules.cellRecency(lastSeenMs: now + 2 * MIN, nowMs: now, radarFrameMs: nil).ageMinutes == 0)
        }
        test("with no radar grid there is nothing to compare against") {
            precondition(StormRules.cellRecency(lastSeenMs: now, nowMs: now, radarFrameMs: nil).behindMinutes == nil)
            precondition(StormRules.radarOffsetLabel(nil, t) == nil)
        }
        test("the two products on the same step say nothing") {
            precondition(StormRules.radarOffsetLabel(0, t) == nil)
            precondition(StormRules.radarOffsetLabel(StormRules.sameFrameMinutes - 0.1, t) == nil)
            precondition(StormRules.radarOffsetLabel(-(StormRules.sameFrameMinutes - 0.1), t) == nil)
        }
        test("a detection a frame behind the radar says so") {
            let behind = StormRules.cellRecency(lastSeenMs: now - 10 * MIN, nowMs: now, radarFrameMs: now - 5 * MIN).behindMinutes
            precondition(behind == 5)
            precondition(StormRules.radarOffsetLabel(behind, t) == "storm.radar_offset.behind(m=5)")
        }
        test("a detection ahead of the composite is reported rather than rounded away") {
            precondition(StormRules.radarOffsetLabel(-5, t) == "storm.radar_offset.ahead(m=5)")
        }
        test("the offset is against the radar frame, not the clock") {
            let r = StormRules.cellRecency(lastSeenMs: now - 30 * MIN, nowMs: now, radarFrameMs: now - 30 * MIN)
            precondition(r.ageMinutes == 30 && r.behindMinutes == 0 && StormRules.radarOffsetLabel(r.behindMinutes, t) == nil)
        }
    }

    // MARK: - cellStatus.test.ts

    static func cellStatus() {
        func status(_ active: Bool, _ children: [String] = [], _ age: Double) -> StormRules.StatusKind {
            StormRules.cellStatus(active: active, childCodes: children, ageMinutes: age)
        }
        test("a recently detected active cell is live") {
            precondition(status(true, [], 3) == .live && StormRules.statusLabel(.live, t) == "storm.status.live")
        }
        test("one missed run is jitter, not staleness") { precondition(status(true, [], 6) == .live) }
        test("an active cell nothing has been heard from is stale") {
            precondition(status(true, [], StormRules.staleMinutes) == .stale && status(true, [], 40) == .stale)
        }
        test("an ended cell with children was superseded, not lost") {
            precondition(status(false, ["B"], 5) == .superseded && StormRules.statusLabel(.superseded, t) == "storm.status.superseded")
        }
        test("an ended cell with nowhere to go dissipated") { precondition(status(false, [], 5) == .ended) }
        test("age never promotes an ended cell back to stale") { precondition(status(false, [], 300) == .ended) }
    }

    // MARK: - cellLineage.test.ts

    static var clock = 0
    static func lineageCell(_ code: String, _ parents: [String] = [], _ children: [String] = []) -> (String, TrackProperties) {
        clock += 1
        var c = TrackProperties(code: code, firstSeen: String(format: "2026-09-20T%02d:%02d:00Z", 10 + clock / 60, clock % 60), lastSeen: "2026-09-20T11:00:00Z")
        c.parentCodes = parents
        c.childCodes = children
        c.maxSeverity = 1
        c.maxDbz = 55
        return (code, c)
    }

    static func known(_ entries: (String, TrackProperties)...) -> [String: TrackProperties] {
        Dictionary(entries, uniquingKeysWith: { $1 })
    }

    static func cellLineage() {
        typealias R = StormRules
        let c = lineageCell
        test("a cell with no relatives has no graph to draw") {
            precondition(R.buildLineage(known(c("solo", [], [])), "solo") == R.Lineage())
        }
        test("a split is one parent and two children") {
            let map = known(c("p", [], ["a", "b"]), c("a", ["p"], []), c("b", ["p"], []))
            let lineage = R.buildLineage(map, "a")
            precondition(lineage.nodes.map(\.code).sorted() == ["a", "b", "p"])
            precondition(lineage.edges.sorted { $0.to < $1.to } == [R.LineageEdge(from: "p", to: "a"), R.LineageEdge(from: "p", to: "b")])
            precondition(R.nodeRole(lineage, "p") == "split")
        }
        test("a merge is several parents into one child") {
            let map = known(c("x", [], ["m"]), c("y", [], ["m"]), c("z", [], ["m"]), c("m", ["x", "y", "z"], []))
            let lineage = R.buildLineage(map, "m")
            precondition(lineage.edges.count == 3 && R.nodeRole(lineage, "m") == "merge")
        }
        test("an edge named by both of its endpoints is drawn once") {
            precondition(R.buildLineage(known(c("p", [], ["c"]), c("c", ["p"], [])), "c").edges == [R.LineageEdge(from: "p", to: "c")])
        }
        test("edges run the way time does, whichever end you start from") {
            let map = known(c("p", [], ["c"]), c("c", ["p"], []))
            precondition(R.buildLineage(map, "p").edges == R.buildLineage(map, "c").edges)
        }
        test("the walk reaches a whole family, not just one hop") {
            let map = known(c("g", [], ["p"]), c("p", ["g"], ["c"]), c("c", ["p"], []))
            precondition(R.reachable(map, "c").sorted() == ["c", "g", "p"])
        }
        test("a relative that has not been fetched is not a node") {
            let map = known(c("c", ["elsewhere"], []))
            precondition(R.buildLineage(map, "c") == R.Lineage() && R.missingRelatives(map, "c") == ["elsewhere"])
        }
        test("nothing is asked for twice, or asked for once it is held") {
            precondition(R.missingRelatives(known(c("a", [], ["b", "gone"]), c("b", ["a"], ["gone"])), "a") == ["gone"])
        }
        test("the walk is bounded, whatever the feed sends") {
            var map: [String: TrackProperties] = [:]
            for i in 0 ..< 100 {
                let (code, track) = c("n\(i)", i > 0 ? ["n\(i - 1)"] : [], ["n\(i + 1)"])
                map[code] = track
            }
            precondition(R.reachable(map, "n0").count == R.maxFamily)
        }
        test("a cycle terminates rather than walking forever") {
            precondition(R.reachable(known(c("a", ["b"], ["b"]), c("b", ["a"], ["a"])), "a").sorted() == ["a", "b"])
        }
        test("nodes come out oldest first") {
            precondition(R.buildLineage(known(c("first", [], ["second"]), c("second", ["first"], [])), "second").nodes.map(\.code) == ["first", "second"])
        }
        test("the same family comes out identical from whichever node you enter it") {
            let map = known(c("gp", [], ["a"]), c("a", ["gp"], ["m"]), c("b", [], ["m"]), c("m", ["a", "b"], ["x", "y"]),
                            c("x", ["m"], []), c("y", ["m"], []))
            let fromRoot = R.buildLineage(map, "gp")
            for code in ["a", "b", "m", "x", "y"] {
                let other = R.buildLineage(map, code)
                precondition(other.nodes.map(\.code) == fromRoot.nodes.map(\.code) && other.edges == fromRoot.edges)
                // The native layout keeps the same lanes too, whichever node is open.
                let layout = { (root: String) in
                    R.familyLayout(R.buildLineage(map, root), known: map, nowMs: 0, clock: { $0 }, t: t)!.nodes.map { "\($0.code)@\($0.x),\($0.y)" }
                }
                precondition(layout(code) == layout("gp"))
            }
        }
        test("cells that start in the same minute keep a stable order") {
            func same(_ code: String, _ parents: [String], _ children: [String] = []) -> (String, TrackProperties) {
                var c = TrackProperties(code: code, firstSeen: "2026-09-20T16:45:00Z", lastSeen: "2026-09-20T17:00:00Z")
                c.parentCodes = parents
                c.childCodes = children
                c.maxSeverity = 1
                c.maxDbz = 60
                return (code, c)
            }
            let map = known(same("p", [], ["twinB", "twinA"]), same("twinA", ["p"]), same("twinB", ["p"]))
            func order(_ root: String) -> [String] { R.buildLineage(map, root).nodes.map(\.code) }
            precondition(order("twinA") == order("twinB") && order("twinA") == order("p"))
        }
        let MINUTE = 60_000.0
        test("a single moment sits at the start") {
            precondition(R.axisOffsets([0], minGap: 40, pxPerMs: 1) == [0] && R.axisOffsets([], minGap: 40, pxPerMs: 1) == [])
        }
        test("positions are spaced by how much time passed") {
            precondition(R.axisOffsets([0, 10 * MINUTE, 20 * MINUTE], minGap: 10, pxPerMs: 2 / MINUTE) == [0, 20, 40])
        }
        test("a longer gap is drawn as a longer gap") {
            let a = R.axisOffsets([0, 10 * MINUTE, 40 * MINUTE], minGap: 10, pxPerMs: 1 / MINUTE)
            precondition(a[2] - a[1] > a[1] - a[0])
        }
        test("nodes never land on top of each other, however close in time") {
            precondition(R.axisOffsets([0, MINUTE, 2 * MINUTE], minGap: 40, pxPerMs: 1 / MINUTE) == [0, 40, 80])
        }
        test("positions only ever run forwards") {
            let a = R.axisOffsets([0, MINUTE, 90 * MINUTE, 91 * MINUTE], minGap: 36, pxPerMs: 1.5 / MINUTE)
            for i in 1 ..< a.count { precondition(a[i] > a[i - 1]) }
        }
    }

    // MARK: - cellPulse.test.ts

    static func cellPulse() {
        typealias P = StormPulse
        test("a cycle is one dash and one gap, nine notches") {
            precondition(P.dashPeriod == P.dash.0 + P.dash.1)
            var angles = Set<Double>()
            var ms = 0.0
            while ms < P.tickMs * P.dashPeriod * 3 {
                angles.insert(P.ringAngle(ms))
                ms += 10
            }
            precondition(Double(angles.count) == P.dashPeriod)
        }
        test("the pattern closes round the ring, so the turn loops without a jump") {
            precondition(P.ringPathLength.truncatingRemainder(dividingBy: P.dashPeriod) == 0)
            precondition(abs(P.ringPathLength / (2 * Double.pi * P.ringRadius) - 1) < 0.05)
            precondition(P.dashPeriod * P.notchDegrees * P.ringPathLength / 360 == P.dashPeriod)
            precondition(P.ringPathLength == 72)
        }
        test("it holds still between ticks rather than sweeping") {
            precondition(P.ringAngle(0) == P.ringAngle(P.tickMs - 1) && P.ringAngle(0) != P.ringAngle(P.tickMs))
        }
        test("the dashes travel the way the pattern is read") {
            for tick in 1 ..< Int(P.dashPeriod) {
                precondition(P.ringAngle(Double(tick) * P.tickMs) > P.ringAngle(Double(tick - 1) * P.tickMs))
            }
        }
        test("every live cell steps together, off one clock") {
            precondition(P.ringAngle(1_000_000) == P.ringAngle(1_000_000) && P.ringAngle(0) == P.ringAngle(P.tickMs * P.dashPeriod))
        }
        test("a cell detected in the newest run is live") { precondition(P.isLive(0)) }
        test("one missed detection does not take a live storm off the map") { precondition(P.isLive(5) && P.isLive(P.liveMinutes)) }
        test("a cell that has stopped being detected stops pinging") { precondition(!P.isLive(P.liveMinutes + 0.1) && !P.isLive(85)) }
        test("a pan slides the rings together; anything else lays them out again") {
            let laid = P.RingLayout(resolution: 611.5, rotation: 0, revision: 7, selected: nil)
            precondition(P.onlySlid(laid, laid))
            var zoom = laid
            zoom.resolution = 600
            var turn = laid
            turn.rotation = 0.1
            var cells = laid
            cells.revision = 8
            var picked = laid
            picked.selected = "A"
            precondition(!P.onlySlid(laid, zoom) && !P.onlySlid(laid, turn) && !P.onlySlid(laid, cells) && !P.onlySlid(laid, picked))
            precondition(!P.onlySlid(nil, laid))
        }
        func atZoom(_ zoom: Double) -> Double { 156_543.033_928_041 / pow(2, zoom) }
        test("cells no longer detected are drawn from zoom 10 in, not from a country away") {
            precondition(P.endedMinZoom == 10)
            precondition(P.showsEnded(atZoom(11)) && P.showsEnded(atZoom(10)) && !P.showsEnded(atZoom(9.5)) && !P.showsEnded(atZoom(6)))
        }
        let zoomedOut = atZoom(6)
        func ring(_ storm: String, _ history: Double, _ px: Double = 0, _ severity: Int = 0, _ resolution: Double = zoomedOut) -> P.RingSpot {
            P.RingSpot(storm: storm, x: px * resolution, y: 0, severity: severity, historyMinutes: history)
        }
        func crowded(_ rings: [P.RingSpot], _ selected: String? = nil) -> [String] {
            P.crowdedOut(rings, resolution: zoomedOut, selected: selected).sorted()
        }
        test("a new storm on an established one's ring gives way to it, zoomed out") {
            precondition(crowded([ring("new", 0, 10), ring("old", 60)]) == ["new"])
        }
        test("of two storms with a history on each other, the one tracked longer keeps its ring") {
            precondition(crowded([ring("younger", 30, 10), ring("older", 60)]) == ["younger"])
        }
        test("a more severe storm keeps its ring over one tracked longer") {
            precondition(crowded([ring("new", 0, 10, 1), ring("old", 60, 0, 0)]) == ["old"])
        }
        test("severe storms keep their rings however close they are") {
            precondition(crowded([ring("red", 0, 5, P.severe), ring("purple", 60, 0, P.severe + 1)]) == [])
        }
        test("rings that do not touch are all kept") {
            precondition(crowded([ring("new", 0, P.ringOverlapPx + 1), ring("old", 60)]) == [])
            precondition(crowded([ring("new", 0, P.ringOverlapPx - 1), ring("old", 60)]) == ["new"])
        }
        test("a ring is measured against the rings kept, not the ones given way") {
            precondition(crowded([ring("old", 60), ring("a", 10, 20), ring("b", 5, 40)]) == ["a"])
        }
        test("the selected storm keeps its ring, and a severe one next to it does too") {
            precondition(crowded([ring("new", 0, 10), ring("old", 60)], "new") == ["old"])
            precondition(crowded([ring("new", 0, 10), ring("red", 60, 0, P.severe)], "new") == [])
        }
        test("from zoom 10 in, where the rings come apart, no ring gives way") {
            let close = atZoom(P.endedMinZoom)
            precondition(P.crowdedOut([ring("new", 0, 10, 0, close), ring("old", 60, 0, 0, close)], resolution: close, selected: nil).isEmpty)
            let far = atZoom(P.endedMinZoom - 0.5)
            precondition(P.crowdedOut([ring("new", 0, 10, 0, far), ring("old", 60, 0, 0, far)], resolution: far, selected: nil).count == 1)
        }
    }

    // MARK: - timeTicks.test.ts

    static func timeTicks() {
        let MIN = 60_000.0
        func at(_ h: Int, _ m: Int) -> Double { StormTime.ms(String(format: "2026-09-20T%02d:%02d:00Z", h, m)) }
        func hhmm(_ t: Double) -> String { String(StormTime.iso(t).dropFirst(11).prefix(5)) }
        func ticks(_ from: Double, _ to: Double, _ target: Double = 4) -> [Double] { StormRules.timeTicks(from, to, target: target) }
        test("ticks land on the clock, not on the data") {
            let labels = ticks(at(16, 7), at(16, 52)).map(hhmm)
            precondition(labels.contains("16:15") && labels.contains("16:30") && labels.contains("16:45"))
        }
        test("some tick is always shown, however short the window") {
            precondition(ticks(at(16, 0), at(16, 3)).count >= 2 && ticks(at(16, 0), at(16, 0) + 30_000).count >= 2)
        }
        test("an end close to a step tick is dropped rather than printed over it") {
            let labels = ticks(at(14, 35), at(18, 28)).map(hhmm)
            precondition(!labels.contains("14:35") && !labels.contains("18:28"), labels.joined(separator: " "))
            precondition(labels.contains("15:00") && labels.contains("18:00"))
        }
        test("an end far from any tick is still labelled") {
            precondition(ticks(at(16, 5), at(17, 55), 4).map(hhmm).contains("16:05"))
        }
        test("the ends are labelled unless a tick is already there") {
            let exact = ticks(at(16, 0), at(17, 0)).map(hhmm)
            precondition(exact.first == "16:00" && exact.last == "17:00" && Set(exact).count == exact.count)
        }
        test("a long track steps up rather than printing forty labels") { precondition(ticks(at(8, 0), at(20, 0)).count <= 8) }
        test("every step is a whole hour or divides one") {
            for m in StormRules.stepsMinutes { precondition(60.truncatingRemainder(dividingBy: m) == 0 || m.truncatingRemainder(dividingBy: 60) == 0) }
        }
        test("nothing is emitted twice, and they run forwards") {
            let a = ticks(at(16, 7), at(18, 22))
            precondition(a.sorted() == a && Set(a).count == a.count)
        }
        test("a degenerate window does not hang or invent a range") {
            precondition(ticks(at(16, 0), at(16, 0)) == [at(16, 0)] && ticks(at(16, 0), at(15, 0)) == [at(16, 0)] && ticks(.nan, at(16, 0)) == [])
        }
        test("ticks stay inside the window they label") {
            let from = at(16, 7), to = at(17, 41)
            for t in ticks(from, to) { precondition(t >= from && t <= to) }
        }
        test("the step scales with the span rather than the count of readings") {
            let short = ticks(at(16, 0), at(16, 40)), long = ticks(at(16, 0), at(22, 0))
            precondition(long[2] - long[1] > short[2] - short[1] && short[2] - short[1] >= 5 * MIN)
        }
    }

    // MARK: - swipeAway.test.ts (the gesture plumbing is `StormHintBar`'s, in the UI tests)

    static func swipeAway() {
        typealias R = StormRules
        test("a tap is not a swipe") {
            precondition(R.decideAxis(0, 0) == .undecided && R.decideAxis(R.swipeSlop - 1, R.swipeSlop - 1) == .undecided && R.decideAxis(-3, 2) == .undecided)
        }
        test("the longer travel wins once there is enough of it") {
            precondition(R.decideAxis(-20, 4) == .x && R.decideAxis(-4, 20) == .y && R.decideAxis(20, -4) == .x)
        }
        test("a vertical drag is somebody else's") { precondition(R.decideAxis(2, 30) == .y) }
        test("a short pull springs back") {
            precondition(!R.shouldClear(-10, width: 300) && !R.shouldClear(-(300 * R.swipeCommit) + 1, width: 300))
        }
        test("a long pull clears") { precondition(R.shouldClear(-(300 * R.swipeCommit), width: 300) && R.shouldClear(-400, width: 300)) }
        test("a rightward pull never clears") { precondition(!R.shouldClear(40, width: 300)) }
        test("a zero-width element cannot be cleared by accident") { precondition(!R.shouldClear(-5, width: 0)) }
        test("a parked panel follows a rightward drag back shut") {
            precondition(R.pullTo(R.swipeDetent, 0, width: 300) == R.swipeDetent)
            precondition(R.pullTo(R.swipeDetent, 40, width: 300) == R.swipeDetent - 40)
            precondition(R.pullTo(R.swipeDetent, R.swipeDetent, width: 300) == 0 && R.pullTo(R.swipeDetent, 400, width: 300) == 0)
        }
        test("a pull tracks the finger to the detent, then gives only part of the travel") {
            precondition(R.pullTo(0, -50, width: 300) == 50 && R.pullTo(0, -R.swipeDetent, width: 300) == R.swipeDetent)
            let past = R.pullTo(0, -(R.swipeDetent + 100), width: 300)
            precondition(past > R.swipeDetent && past < R.swipeDetent + 100 && R.pullTo(0, -5000, width: 300) == 300)
        }
    }

    // MARK: - The data service's answers (spec §6 examples)

    static func decoding() {
        test("a storm list decodes with every default, and a bad storm is dropped, not the answer") {
            let json = """
            {"type":"FeatureCollection","features":[
             {"type":"Feature","id":"01M5B6JFB03P039924D32DW34Y","geometry":{"type":"Point","coordinates":[5.36391,50.52433]},
              "properties":{"id":"01M5B6JFB03P039924D32DW34Y","born_at":"2026-10-19T23:05:00Z","last_seen":"2026-10-20T00:25:00Z",
              "status":"active","merged_into":null,"split_from":null,"primary_track":"2026102000109874043000",
              "primary_product":"dwd/konrad3d","primary_domain":"de","heading_deg":19.6,"speed_kmh":38.9,"severity":0,
              "peak_dbz":53.54,"hail":false,"meso":false,
              "placement":{"place":"Modave","kind":"village","distance_km":10.2,"direction":"NE","bearing_deg":25.5},
              "bbox":{"west":5.0194,"south":50.3072,"east":5.36391,"north":50.52433},
              "path":{"type":"LineString","coordinates":[[5.0435,50.3072],[5.0224,50.3229],[5.36391,50.52433]]},
              "tracks":[{"product":"dwd/konrad3d","domain":"de","track":"2026101923459874043001"}]}},
             {"type":"Feature","id":"broken","geometry":null,"properties":{}},
             {"type":"Feature","id":"01M5B80860JKDK3VE5XKB53NV1","geometry":{"type":"Point","coordinates":[2.0,48.0]},
              "properties":{"id":"01M5B80860JKDK3VE5XKB53NV1","born_at":"2026-10-19T23:30:00Z","last_seen":"2026-10-20T00:00:00Z",
              "status":"merged","merged_into":"01M5B54PG0JCW7RPGNMVSJM6H6","primary_product":"meteocool/tracker",
              "placement":null,"bbox":{"west":2,"south":48,"east":2,"north":48},"path":{"type":"Point","coordinates":[2.0,48.0]}}}]}
            """
            let answer = StormJSON.storms(Data(json.utf8))!
            precondition(answer.features.count == 2)
            let a = answer.features[0].properties
            precondition(a.placement?.place == "Modave" && a.placement?.distanceKm == 10.2 && a.path.points.count == 3)
            precondition(a.tracks.first?.track == "2026101923459874043001" && a.primaryTrack == "2026102000109874043000")
            let b = answer.features[1].properties
            precondition(b.severity == 0 && !b.hail && b.tracks.isEmpty && b.path == .point(LonLat(2, 48)) && b.mergedInto != nil)
        }
        test("a detail's KONRAD3D track decodes its series, forecast and structure") {
            let json = """
            {"storm":{"type":"Feature","id":"S","geometry":{"type":"Point","coordinates":[5.36,50.52]},
              "properties":{"id":"S","born_at":"2026-10-19T23:05:00Z","last_seen":"2026-10-20T00:25:00Z","status":"active",
              "bbox":{"west":5,"south":50,"east":5.4,"north":50.6},"path":{"type":"Point","coordinates":[5.36,50.52]}}},
             "konrad3d":[{"type":"Feature","id":"C","geometry":{"type":"LineString","coordinates":[[5.3,50.4],[5.36,50.52]]},
              "properties":{"code":"2026102000109874043000","first_seen":"2026-10-20T00:10:00Z","last_seen":"2026-10-20T00:25:00Z",
              "n_steps":4,"active":true,"max_severity":0,"max_dbz":57.37,"vil_max":8.081,"echo_top_max_m":4459.0,
              "hail_minutes":0,"deviation_deg":12.4,"parent_codes":[],"child_codes":[],
              "series":[{"t":"2026-10-20T00:25:00Z","lon":5.36391,"lat":50.52433,"identifier":32,"severity":0,"max_dbz":53.54,
                "echo_top_m":3966.0,"gust_kmh":38.855,"lightning_rate":0,"speed_kmh":38.855,"heading_deg":19.6397}],
              "forecast":[{"t":"2026-10-20T00:30:00Z","lon":5.37853,"lat":50.55036,"major_km":1.802,"minor_km":1.639,"angle_deg":133.49}],
              "polygon":[[5.3114,50.59149],[5.30833,50.58919],[5.31,50.6]],
              "structure":[{"dbz":30,"area_km2":76.8125,"top_m":3966.0,"volume_km3":171.859375,"rings":null}],
              "volume":null}}],
             "tracks":[{"id":"t","product":"meteocool/tracker","domain":"fr","kind":"core","first_seen":"2026-10-19T23:05:00Z",
              "last_seen":"2026-10-20T00:20:00Z","active":true,"parent_tracks":[],"child_tracks":[],"max_peak_dbz":52.0,
              "bbox":{"west":5,"south":50,"east":5.4,"north":50.6},"path":{"type":"LineString","coordinates":[[5,50],[5.1,50.1]]},
              "n_features":1,"features":[{"id":"f","kind":"core","valid_at":"2026-10-19T23:25:00Z","parent":"p",
                "centroid":{"type":"Point","coordinates":[5.0194,50.3724]},"peak":{"type":"Point","coordinates":[5.0422,50.3787]},
                "peak_dbz":50.5,"area_km2":28.7,"outline":{"type":"Polygon","coordinates":[[[4.9,50.4],[4.95,50.4],[4.9,50.45]]]}}]}]}
            """
            let d = StormJSON.detail(Data(json.utf8))!
            let c = d.konrad3d[0]
            precondition(c.echoTopMaxM == 4459 && c.vilMax == 8.081 && c.series[0].gustKmh == 38.855 && c.series[0].lightningRate == 0)
            precondition(c.forecast[0].majorKm == 1.802 && c.structure[0].topM == 3966 && c.polygon?.count == 3 && c.volume == nil)
            precondition(d.tracks[0].features[0].outline[0].count == 3 && d.tracks[0].features[0].parent == "p")
        }
        test("timestamps read as core's Date does, and write as its toISOString") {
            precondition(StormTime.ms("1970-01-01T00:00:00Z") == 0)
            precondition(StormTime.ms("2026-10-20T00:25:00Z") == StormTime.ms("2026-10-20T00:25:00.000Z"))
            precondition(StormTime.ms("2026-10-20T02:25:00+02:00") == StormTime.ms("2026-10-20T00:25:00Z"))
            precondition(StormTime.iso(StormTime.ms("2026-10-20T00:25:00Z")) == "2026-10-20T00:25:00.000Z")
            precondition(StormTime.iso(StormTime.ms("1999-12-31T23:59:59.250Z")) == "1999-12-31T23:59:59.250Z")
            precondition(StormTime.ms("not a time").isNaN)
            let date = ISO8601DateFormatter().date(from: "2026-10-20T00:25:00Z")!
            precondition(StormTime.ms("2026-10-20T00:25:00Z") == date.timeIntervalSince1970 * 1000)
        }
    }

    // MARK: - The native extras (spec §11.1)

    static func extras() {
        typealias D = StormDrawing
        test("worldExtent across the antimeridian asks for every longitude") {
            let across = D.worldExtent(D.Extent(west: 170, south: -95, east: 190, north: 40))
            precondition(across == D.Extent(west: -180, south: -90, east: 180, north: 40))
            precondition(D.worldExtent(D.Extent(west: 370, south: 40, east: 375, north: 50)) == D.Extent(west: 10, south: 40, east: 15, north: 50))
            precondition(D.worldExtent(D.Extent(west: -200, south: 0, east: 200, north: 10)).west == -180)
            precondition(D.covers(D.Extent(west: 0, south: 0, east: 10, north: 10), D.Extent(west: 1, south: 1, east: 9, north: 9)))
            precondition(!D.covers(nil, D.Extent(west: 1, south: 1, east: 9, north: 9)))
            precondition(D.padExtent(D.Extent(west: 0, south: 0, east: 4, north: 2), 0.25) == D.Extent(west: -1, south: -0.5, east: 5, north: 2.5))
        }
        test("age opacity is bucketed to 1, 0.6, 0.4 and 0.2") {
            precondition([0.0, 19, 20, 39, 40, 59, 60, 300].map(D.ageOpacity) == [1, 1, 0.6, 0.6, 0.4, 0.4, 0.2, 0.2])
        }
        test("lead labels thin out by resolution, and count down from now") {
            let now = T0
            func label(_ lead: Double, _ res: Double) -> String? { D.leadLabel(now + lead * 60_000, lead, resolution: res, now: now) }
            precondition(label(20, 700) == "+20 min" && label(15, 700) == nil && label(60, 700) == "+60 min")
            precondition(label(15, 400) == "+15 min" && label(10, 400) == nil)
            precondition(label(10, 200) == "+10 min" && label(5, 200) == nil)
            precondition(label(5, 100) == "+5 min" && label(0, 100) == nil)
            precondition(D.leadLabel(now - 60_000, 5, resolution: 100, now: now) == nil, "a passed moment has no label")
            precondition(D.leadLabel(now + 7.5 * 60_000, 15, resolution: 100, now: now) == "+8 min", "rounded half up")
        }
        test("an ellipse at bearing 90 points east") {
            let ring = D.ellipseRing4326(10, 50, 10, 2, 90)
            precondition(ring.count == 37 && ring[0].lon > 10.1 && abs(ring[0].lat - 50) < 1e-9)
            precondition(abs(ring[18].lon - (10 - (ring[0].lon - 10))) < 1e-9)
            precondition(D.leadingTip(ring, LonLat(9.9, 50)) == ring[0])
        }
        test("cell readings print as core's") {
            var track = cell("C")
            track.maxDbz = 53.54
            track.echoTopMaxM = 4459
            track.vilMax = nil
            track.series = [CellStep(t: at(0), lon: 5, lat: 50, gustKmh: 38.855, lightningRate: 31, speedKmh: 38.855, headingDeg: 19.6)]
            let en = catalogue("en")
            let readings = StormRules.cellReadings(track, en)
            precondition(readings.map(\.text) == ["53.5 dBZ", "4.5 km", "–", "39 km/h NNE", "39 km/h", "31/5 min"], readings.map(\.text).joined(separator: "|"))
            precondition(readings[0].band == 1 && readings[0].bandName == "moderate" && abs(readings[0].fill! - 0.699) < 0.001)
            precondition(readings[2].band == nil && readings[2].fill == 0)
            precondition(readings.map(\.label) == ["peak", "echo top", "VIL", "motion", "gusts", "lightning"])
        }
        test("durations read as core's") {
            let en = catalogue("en")
            precondition(StormRules.duration(59.6, en) == "60 min" && StormRules.duration(60, en) == "1 h" && StormRules.duration(127, en) == "2 h 7 min")
            precondition(StormRules.duration(0, en) == "0 min")
        }
        test("placement reads long and short") {
            let en = catalogue("en")
            let modave = CellPlacement(place: "Modave", distanceKm: 10.2, direction: "NE", bearingDeg: 25.5, kind: "village")
            precondition(StormRules.placementLabel(modave, en) == "10 km NE of Modave" && StormRules.placementLabel(modave, en, style: .short) == "NE of Modave")
        }
        test("a flat series still gets a box") {
            let scale = StormRules.verticalScale([50, 50, 50], y0: 57, y1: 9, target: 3)!
            precondition(scale.min < 50 && scale.max > 50 && scale.at(50) < 57 && scale.at(50) > 9)
            precondition(StormRules.verticalScale([50], y0: 57, y1: 9) == nil)
            precondition(StormRules.niceTicks(0, 10, target: 4) == [0, 2.5, 5, 7.5, 10])
        }
        test("the family layout keeps nodes apart, oldest left, in lanes") {
            let c = lineageCell
            let map = known(c("p", [], ["a", "b"]), c("a", ["p"], []), c("b", ["p"], []))
            let layout = StormRules.familyLayout(StormRules.buildLineage(map, "a"), known: map, nowMs: StormTime.ms("2026-09-20T18:00:00Z"),
                                                 clock: { String($0.dropFirst(11).prefix(5)) }, t: t)!
            let p = layout.nodes.first { $0.code == "p" }!, a = layout.nodes.first { $0.code == "a" }!, b = layout.nodes.first { $0.code == "b" }!
            precondition(p.x < a.x && a.x < b.x && a.y != b.y && abs(a.y - b.y) >= StormRules.nodeH)
            precondition(layout.edges.count == 2 && a.isSelf && a.peak == "55 dBZ")
            precondition(layout.nowX != nil && layout.width >= layout.nowX! + 12)
            precondition(layout.height == 8 + 2 * StormRules.nodeH + 10 + StormRules.axisH)
        }
    }
}

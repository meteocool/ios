//
//  StormStore.swift
//  meteocool
//
//  The storms the map holds and the one selected: core's `selectedStorm`,
//  `stormDetails`, `lib/stormResolver.ts`, `lib/StormManager.ts` (fetching
//  half) and the family walk of `StormDetails.svelte`.
//

import Foundation
import MapKit

/// What the storm layer shows and what is selected, shared by the marks,
/// the hint bar, the sheet and the details.
@MainActor
final class StormStore: ObservableObject {
    /// How the layer draws (`App.svelte:431-478`): hidden on a forecast step
    /// or with the layer off, the present, or rewound to an earlier frame.
    enum Frame: Equatable {
        case hidden
        case now
        case at(Double)
    }

    /// The storms of the last `/storms` answer.
    @Published private(set) var held: [Storm] = []
    /// The groups of them that are one system, from `/storms/groups` for
    /// the same box and window; none from a backend without groups.
    @Published private(set) var groups: [StormSystem] = []
    @Published var selection: StormSelection? {
        didSet {
            if selection == nil { details = false }
            if StormSelect.selectionKey(selection) != StormSelect.selectionKey(oldValue), !StormSelect.isResolution(oldValue, selection) {
                named = nil
                // Every storm opens cut along its own track: an angle turned
                // for the last one means nothing for this one. A link's
                // angle waits for the storm it opens (App.svelte's `cutFor`).
                map?.model.cut.stopSweep(keep: false)
                map?.model.cut.set(selection == nil ? 0 : linkCut ?? 0)
                if selection != nil { linkCut = nil }
            }
            selectionChanged(from: oldValue)
        }
    }
    /// The panel or sheet is open, not only the marks (`stormDetails`).
    @Published var details = false
    @Published private(set) var frame = Frame.now
    /// The family of the open cell, by code, and whether more is coming.
    @Published private(set) var family: [String: TrackProperties] = [:]
    @Published private(set) var familyLoading = false
    /// A place name for a storm without placement or track (`reverseGeocode`).
    @Published private(set) var named: (name: String, area: String?)?
    /// Bumped when marks must be drawn again: an answer, a frame, a selection.
    @Published private(set) var revision = 0

    /// What a bump of `revision` was, for how the marks change
    /// (`StormEasing`): a new answer and a step of the player ease, a change
    /// of what is viewed applies at once, and a window opened or left drops
    /// what was drawn.
    enum Change: Equatable {
        case update
        /// A step of the player, this long (ms) after the one before it.
        case step(gapMs: Double)
        case view
        case drop
    }

    /// The changes since the marks last drew, as one: dropping wins, then
    /// applying at once.
    private var pendingChange: Change?
    /// When the player last stepped (ms of uptime).
    private var lastStepMs: Double?

    private func changed(_ change: Change) {
        switch (pendingChange, change) {
        case (.drop?, _), (.view?, .update), (.view?, .step): break
        default: pendingChange = change
        }
        revision += 1
    }

    /// What the marks are to draw, once: nil when nothing has changed.
    func takeChange() -> Change? {
        defer { pendingChange = nil }
        return pendingChange
    }
    /// A link's slice, for the storm it is opening (`cut`).
    var linkCut: Double?
    /// A past window: every storm that overlapped it, rewound to the step
    /// on screen; nil live.
    private(set) var window: RadarWindow?

    weak var map: NativeMapContext?
    /// The box the held storms were asked for.
    private var fetched: StormDrawing.Extent?
    /// The box the request out now asks for, while it is out. A move inside
    /// it waits for that answer instead of asking again: the tray settling
    /// just after the first fetch nudges the view a few points, and that
    /// sent the storms and the groups twice.
    private var requested: StormDrawing.Extent?
    private var token = 0
    /// When the backend last had no groups (ms), so it is not asked again on
    /// every pan; nil for never.
    private var groupsAbsentAt: Double?
    /// Each storm's newest detail, so one reopened shows its history at once.
    private var detailCache = StormSelect.DetailCache()
    private var detailInFlight: String?
    private var familyRoot: String?
    private var familyIncomplete = false
    private var familyToken = 0

    /// `WINDOW_MINUTES`, `BBOX_PADDING`.
    static let windowMinutes = 180.0
    static let padding = 0.25

    var twoStage: Bool {
        map?.view.traitCollection.horizontalSizeClass != .regular
    }

    /// Where the drawn storms are (nil in the present).
    var at: Double? {
        if case .at(let ms) = frame { return ms }
        return nil
    }

    // MARK: - Fetching

    /// One `reload`'s two answers, applied together once both are in.
    private final class Answer {
        var storms: [Storm]?
        var groups: [StormSystem]?
    }

    /// Fetches `/storms` for the view when it left the box fetched, or when
    /// told to (`StormManager.reload`); with it `/storms/groups` for the
    /// same box and window, beside the storms and never in their way: a
    /// failure is no groups, and a backend without them is not asked again
    /// for a while (`StormGroupRules`).
    func reload(force: Bool = false) {
        guard let map, frame != .hidden, let view = Self.extent(of: map.mapView.visibleMapRect) else { return }
        let world = StormDrawing.worldExtent(view)
        if !force, StormDrawing.covers(fetched, world) || StormDrawing.covers(requested, world) { return }
        let padded = StormDrawing.worldExtent(StormDrawing.padExtent(view, Self.padding))
        token += 1
        let mine = token
        requested = padded
        let (since, until) = Self.span(window)
        let answer = Answer()
        func apply() {
            guard let storms = answer.storms, let groups = answer.groups else { return }
            if mine == token { requested = nil }
            guard mine == token else { return }
            fetched = padded
            held = storms
            self.groups = groups
            refreshSelection()
            changed(.update)
        }
        var older: Int?
        #if DEBUG
        // UI tests stand in for a backend from before ratings and groups
        // (`MC_OLDER_STORMS`, the status its `/storms/groups` answers).
        older = ProcessInfo.processInfo.environment["MC_OLDER_STORMS"].flatMap(Int.init)
        #endif
        if let older {
            if StormGroupRules.absent.contains(older) { groupsAbsentAt = Date().timeIntervalSince1970 * 1000 }
            answer.groups = []
        } else if StormGroupRules.asksForGroups(groupsAbsentAt, now: Date().timeIntervalSince1970 * 1000) {
            let url = map.endpoints.stormGroups(minLon: padded.west, minLat: padded.south, maxLon: padded.east, maxLat: padded.north,
                                                since: since, until: until)
            map.fetch(url) { [weak self] data, status in
                guard let self else { return }
                if data == nil, let status, StormGroupRules.absent.contains(status) {
                    self.groupsAbsentAt = Date().timeIntervalSince1970 * 1000
                }
                answer.groups = data.flatMap(StormJSON.groups) ?? []
                apply()
            }
        } else {
            answer.groups = []
        }
        let url = map.endpoints.storms(minLon: padded.west, minLat: padded.south, maxLon: padded.east, maxLat: padded.north,
                                       since: since, until: until)
        map.fetch(url) { [weak self] data, status in
            if let data, let collection = StormJSON.storms(data) {
                answer.storms = collection.features
                if older != nil {
                    for index in answer.storms!.indices {
                        answer.storms![index].properties.rating = nil
                        answer.storms![index].properties.notable = nil
                        answer.storms![index].properties.group = nil
                    }
                }
            } else if status == 404 {
                // No storms served: not an error.
                answer.storms = []
            } else {
                // Nothing to draw, and the next move asks again.
                if mine == self?.token { self?.requested = nil }
                return
            }
            apply()
        }
    }

    /// What `/storms` is asked for: the last three hours live; a window's
    /// whole span, with `until`, so every storm that overlapped it comes.
    private static func span(_ window: RadarWindow?) -> (since: Date, until: Date?) {
        guard let window else { return (Date().addingTimeInterval(-windowMinutes * 60), nil) }
        return (Date(timeIntervalSince1970: TimeInterval(window.start)), Date(timeIntervalSince1970: TimeInterval(window.end)))
    }

    /// A past window opened, or left: the storms held were another time's.
    func setWindow(_ next: RadarWindow?) {
        guard next != window else { return }
        window = next
        token += 1
        fetched = nil
        requested = nil
        held = []
        groups = []
        selection = nil
        changed(.drop)
    }

    /// Socket `storms`, or a wake: fetch again, and the selection's detail.
    func refresh() {
        reload(force: true)
        if let id = selection?.id { fetchDetail(id, key: "refresh:\(Date().timeIntervalSince1970)") }
        if familyIncomplete, !familyLoading, let cell = selection?.cell { walkFamily(cell) }
    }

    /// The selected storm's copy in a new answer replaces the old (`refreshSelection`).
    private func refreshSelection() {
        guard frame == .now, let selection, let id = selection.id,
              let fresh = held.first(where: { $0.properties.id == id }), fresh != selection.summary else { return }
        self.selection = StormSelect.withStorm(selection, fresh)
    }

    // MARK: - Frames

    /// The step on screen: a forecast hides the storms, a past frame rewinds
    /// them, and a selection that did not exist then is dropped.
    func show(_ next: Frame) {
        guard next != frame else { return }
        frame = next
        if let selection {
            switch next {
            case .now: break
            case .at(let ms) where StormSelect.existedBy(selection, ms): break
            default: self.selection = nil
            }
        }
        if next == .now { reload() }
        let nowMs = ProcessInfo.processInfo.systemUptime * 1000
        changed(.step(gapMs: lastStepMs.map { nowMs - $0 } ?? .infinity))
        lastStepMs = nowMs
    }

    // MARK: - Taps

    /// A tap on a storm's mark (its id, or `cell:<code>`), or on nothing.
    func tapped(_ code: String?) {
        let current = StormSelect.Tapped(code: selection?.id ?? selection?.cell.map { "cell:\($0.code)" }, details: details)
        let next = StormSelect.nextSelection(current, code, twoStage: twoStage)
        if let code = next.code, let storm = held.first(where: { $0.properties.id == code }) {
            selection = StormSelect.withStorm(selection, storm)
        } else if next.code == nil {
            selection = nil
        }
        details = next.details
    }

    /// The sheet was closed: on a phone back to the marks (a box of sky
    /// alone has none to keep), elsewhere nothing.
    func closeDetails() {
        guard let selection else { return details = false }
        if selection.id == nil && selection.cell == nil {
            self.selection = nil
        } else if twoStage {
            details = false
        } else {
            self.selection = nil
        }
    }

    /// A storm named by id: the held copy when there is one (merges list).
    func open(id: String, details: Bool = true) {
        selection = StormSelect.byId(id, held: held)
        self.details = details
    }

    // MARK: - Resolver

    private func selectionChanged(from old: StormSelection?) {
        guard let selection else {
            family = [:]
            familyRoot = nil
            return
        }
        if let id = selection.id {
            if let detail = selection.detail { detailCache.remember(detail) }
            if let reopened = detailCache.reopened(selection) {
                // Reopened: the history it had, at once; the change brings
                // this back, to ask for a newer detail if the list has one.
                self.selection = reopened
                return
            }
            let seen = selection.summary?.properties.lastSeen ?? ""
            if detailCache.wantsFetch(selection) { fetchDetail(id, key: "detail:\(id)@\(seen)") }
        } else if let cell = selection.cell {
            resolveSeed(cell)
        }
        if let cell = selection.cell { walkFamily(cell) } else {
            family = [:]
            familyRoot = nil
        }
        if selection.cell == nil, selection.summary?.properties.placement == nil { lookUpName() }
        if selection.id != nil, selection.volume == nil, !offered.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.attachVolume() }
        }
    }

    private func fetchDetail(_ id: String, key: String) {
        guard let map, detailInFlight != key else { return }
        detailInFlight = key
        let asked = StormSelect.selectionKey(selection)
        map.fetch(map.endpoints.data.appendingPathComponent("storms/\(id)")) { [weak self] data, status in
            guard let self else { return }
            if self.detailInFlight == key { self.detailInFlight = nil }
            let detail = data.flatMap(StormJSON.detail)
            // Kept whatever is open now: a storm left before its detail
            // landed shows it when tapped again. One that failed is asked
            // again the next time it is opened.
            if let detail { self.detailCache.remember(detail) }
            guard StormSelect.selectionKey(self.selection) == asked else { return }
            if let detail, let next = StormSelect.withDetail(self.selection, detail) {
                self.selection = next
                self.changed(.view)
            } else if status == 404, self.selection?.summary == nil {
                self.map?.model.toast = CoreStrings.t("storm.toast.storm_gone")
                self.selection = nil
            }
        }
    }

    /// A cell from a link or a family walk: the storm that claims it, among
    /// the held ones or around it (`SEARCH_DEG`, `SEARCH_MINUTES`).
    private func resolveSeed(_ cell: TrackProperties) {
        if let storm = StormSelect.stormClaiming(held, cell.code) {
            selection = StormSelect.withStorm(selection, storm)
            return
        }
        guard let map, let position = selection.flatMap(StormSelect.positionOf) else { return }
        let asked = StormSelect.selectionKey(selection)
        let (since, until) = Self.span(window)
        let url = map.endpoints.storms(minLon: position.lon - 0.5, minLat: position.lat - 0.5, maxLon: position.lon + 0.5,
                                       maxLat: position.lat + 0.5, since: since, until: until)
        map.fetch(url) { [weak self] data, _ in
            guard let self, StormSelect.selectionKey(self.selection) == asked, let data,
                  let around = StormJSON.storms(data)?.features,
                  let storm = StormSelect.stormClaiming(around, cell.code) else { return }
            self.selection = StormSelect.withStorm(self.selection, storm)
        }
    }

    /// A box of sky (core's `cloud`, `openCloudIn3D`): the open storm's own
    /// when it holds the box's patch, else a storm core on its own.
    func openVolume(_ volume: RadarVolume, details: Bool) {
        selection = StormSelect.withVolume(selection, volume)
        self.details = details
    }

    /// The volumes listed now (`offerVolumes`): a storm opened on the flat
    /// map finds the box its patch is in, for its panel's cutaway.
    private var offered: [RadarVolume] = []

    func offerVolumes(_ volumes: [RadarVolume]) {
        offered = volumes
        attachVolume()
    }

    private func attachVolume() {
        guard let current = selection, current.id != nil, current.volume == nil,
              let volume = StormSelect.volumeOfStorm(offered, current) else { return }
        selection?.volume = volume
    }

    /// A box of sky from a link (`cloud=`, core's `restoreCloud`): the listed
    /// one, or one from an earlier scan read from its own file.
    func openCloud(path: String, details: Bool) {
        guard let map else { return }
        let open: (RadarVolume) -> Void = { [weak self] volume in
            self?.openVolume(volume, details: details)
        }
        map.fetch(map.endpoints.volumes(at: map.windowStep)) { [weak self] data, _ in
            if let listed = data.flatMap(StormJSON.volumes)?.first(where: { $0.path == path }) {
                open(listed)
                return
            }
            Task { @MainActor [weak self] in
                guard let url = URL(string: path, relativeTo: NetworkHelper.assetURL),
                      let (body, response) = try? await URLSession.meteocool.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let volume = try? await Task.detached(priority: .userInitiated, operation: { try StormVolume.decode(body) }).value
                else {
                    self?.map?.model.toast = CoreStrings.t("storm.toast.volume_gone")
                    return
                }
                let header = volume.header
                open(RadarVolume(path: path, coverage: header.coverage ?? 0, code: header.code, lon: header.lon, lat: header.lat,
                                 referenceTime: header.referenceTime, network: header.network ?? "de",
                                 scannedAt: header.scannedAt, oldestScanAt: header.oldestScanAt, sites: header.sites ?? [],
                                 tier: header.tier ?? 2))
            }
        }
    }

    /// A cell from a link (`cell=`): fetched, then resolved to its storm.
    func openCell(code: String, details: Bool) {
        guard let map else { return }
        #if DEBUG
        // UI tests open a cell of their own (`MC_CELL_FIXTURE`, a track
        // feature as `/cells/tracks/{code}` sends it): the demo's cells come
        // and go with its replay.
        if let fixture = ProcessInfo.processInfo.environment["MC_CELL_FIXTURE"],
           let track = StormJSON.track(Data(fixture.utf8)), track.code == code {
            selection = StormSelect.withCell(selection, track)
            self.details = details
            return
        }
        #endif
        map.fetch(map.endpoints.data.appendingPathComponent("cells/tracks/\(code)")) { [weak self] data, status in
            guard let self else { return }
            if let data, let track = StormJSON.track(data) {
                self.selection = StormSelect.withCell(self.selection, track)
                self.details = details
            } else if status == 404 {
                self.map?.model.toast = CoreStrings.t("storm.toast.cell_gone")
            }
        }
    }

    /// The open cell's relatives, a few rounds deep (`StormDetails.svelte:638-731`).
    private func walkFamily(_ root: TrackProperties) {
        if familyRoot != root.code, family[root.code] == nil { family = [:] }
        familyRoot = root.code
        family[root.code] = root
        guard !StormRules.missingRelatives(family, root.code).isEmpty, let map else {
            familyLoading = false
            return
        }
        familyToken += 1
        let mine = familyToken
        familyLoading = true
        familyIncomplete = false
        Task { @MainActor [weak self] in
            for _ in 0 ..< 4 {
                guard let self, mine == self.familyToken else { return }
                let wanted = StormRules.missingRelatives(self.family, root.code).prefix(StormRules.maxFamily - self.family.count)
                if wanted.isEmpty { break }
                var added = 0
                for code in wanted {
                    let (track, status) = await Self.track(code, map: map)
                    guard mine == self.familyToken else { return }
                    if let track {
                        self.family[code] = track
                        added += 1
                    } else if status != 404 {
                        self.familyIncomplete = true
                    }
                }
                if added == 0 { break }
            }
            if let self, mine == self.familyToken { self.familyLoading = false }
        }
    }

    private static func track(_ code: String, map: NativeMapContext) async -> (TrackProperties?, Int?) {
        await withCheckedContinuation { continuation in
            map.fetch(map.endpoints.data.appendingPathComponent("cells/tracks/\(code)")) { data, status in
                continuation.resume(returning: (data.flatMap(StormJSON.track), status))
            }
        }
    }

    /// A walked-to relative becomes the open cell.
    func walk(to code: String) {
        guard let track = family[code] else { return }
        selection = StormSelect.withCell(selection, track)
    }

    private func lookUpName() {
        guard let selection, let position = StormSelect.positionOf(selection) else { return }
        let asked = StormSelect.selectionKey(selection)
        let language = CoreStrings.language
        Task { @MainActor [weak self] in
            let place = await ReverseGeocoder.shared.name(latitude: position.lat, longitude: position.lon, language: language)
            guard let self, StormSelect.selectionKey(self.selection) == asked, let place else { return }
            self.named = (place, nil)
        }
    }

    // MARK: - Geometry

    /// The view as lon/lat degrees.
    static func extent(of rect: MKMapRect) -> StormDrawing.Extent? {
        guard !rect.isNull, !rect.isEmpty else { return nil }
        let nw = MKMapPoint(x: rect.minX, y: rect.minY).coordinate
        let se = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate
        let west = rect.minX / MKMapSize.world.width * 360 - 180
        let east = rect.maxX / MKMapSize.world.width * 360 - 180
        return StormDrawing.Extent(west: west, south: se.latitude, east: east, north: nw.latitude)
    }
}

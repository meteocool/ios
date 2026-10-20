//
//  StormStore.swift
//  meteocool
//
//  The storms the map holds and the one selected: core's `selectedStorm`,
//  `stormDetails`, `lib/stormResolver.ts` and the family walk of
//  `StormDetails.svelte`.
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
    @Published var selection: StormSelection? {
        didSet {
            if selection == nil { details = false }
            if StormSelect.selectionKey(selection) != StormSelect.selectionKey(oldValue), !StormSelect.isResolution(oldValue, selection) {
                named = nil
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

    weak var map: NativeMapContext?
    /// The box the held storms were asked for.
    private var fetched: StormDrawing.Extent?
    private var token = 0
    private var lastSeenAtDetail: [String: String] = [:]
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

    /// Fetches `/storms` for the view when it left the box fetched, or when
    /// told to (`StormManager.reload`).
    func reload(force: Bool = false) {
        guard let map, frame != .hidden, let view = Self.extent(of: map.mapView.visibleMapRect) else { return }
        let world = StormDrawing.worldExtent(view)
        if !force, StormDrawing.covers(fetched, world) { return }
        let padded = StormDrawing.worldExtent(StormDrawing.padExtent(view, Self.padding))
        token += 1
        let mine = token
        let since = Date().addingTimeInterval(-Self.windowMinutes * 60)
        let url = map.endpoints.storms(minLon: padded.west, minLat: padded.south, maxLon: padded.east, maxLat: padded.north, since: since)
        map.fetch(url) { [weak self] data, status in
            guard let self, mine == self.token else { return }
            if let data, let collection = StormJSON.storms(data) {
                self.fetched = padded
                self.held = collection.features
                self.refreshSelection()
                self.revision += 1
            } else if status == 404 {
                // No storms served: not an error.
                self.fetched = padded
                self.held = []
                self.revision += 1
            }
        }
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
        revision += 1
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
            let seen = selection.summary?.properties.lastSeen ?? ""
            if selection.detail == nil || (lastSeenAtDetail[id].map { seen > $0 } ?? false) {
                fetchDetail(id, key: "detail:\(id)@\(seen)")
            }
        } else if let cell = selection.cell {
            resolveSeed(cell)
        }
        if let cell = selection.cell { walkFamily(cell) } else {
            family = [:]
            familyRoot = nil
        }
        if selection.cell == nil, selection.summary?.properties.placement == nil { lookUpName() }
    }

    private func fetchDetail(_ id: String, key: String) {
        guard let map, detailInFlight != key else { return }
        detailInFlight = key
        let asked = StormSelect.selectionKey(selection)
        map.fetch(map.endpoints.data.appendingPathComponent("storms/\(id)")) { [weak self] data, status in
            guard let self else { return }
            self.detailInFlight = nil
            guard StormSelect.selectionKey(self.selection) == asked else { return }
            if let data, let detail = StormJSON.detail(data), let next = StormSelect.withDetail(self.selection, detail) {
                self.lastSeenAtDetail[id] = detail.storm.properties.lastSeen
                self.selection = next
                self.revision += 1
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
        let url = map.endpoints.storms(minLon: position.lon - 0.5, minLat: position.lat - 0.5, maxLon: position.lon + 0.5,
                                       maxLat: position.lat + 0.5, since: Date().addingTimeInterval(-Self.windowMinutes * 60))
        map.fetch(url) { [weak self] data, _ in
            guard let self, StormSelect.selectionKey(self.selection) == asked, let data,
                  let around = StormJSON.storms(data)?.features,
                  let storm = StormSelect.stormClaiming(around, cell.code) else { return }
            self.selection = StormSelect.withStorm(self.selection, storm)
        }
    }

    /// A cell from a link (`cell=`): fetched, then resolved to its storm.
    func openCell(code: String, details: Bool) {
        guard let map else { return }
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

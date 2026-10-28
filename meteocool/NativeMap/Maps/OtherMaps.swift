//
//  OtherMaps.swift
//  meteocool
//
//  core's other flat maps: precipitation types (`PrecipitationTypesCapability`)
//  and lightning (`LightningCapability`, `LightningChart.svelte`), and the bar
//  each puts where the radar's tray is (`BottomToolbar.svelte`).
//

import Combine
import MapKit
import SwiftUI
import UIKit

// MARK: - Precipitation types

/// DWD's HG class tiles, coloured by class: 512 px grey PNGs on the asset
/// host, TMS rows, zooms 3–8 and drawn larger past 8, never blended.
final class ClassTileOverlay: MKTileOverlay, @unchecked Sendable {
    private let lock = NSLock()
    private var base: URL?
    private var tilesId: String?

    init() {
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 512, height: 512)
        minimumZ = PrecipTypes.minZoom
        maximumZ = PrecipTypes.maxZoom
        canReplaceMapContent = false
    }

    /// The tile set to draw; a new one forgets the old.
    func set(base: URL, tilesId: String) {
        lock.withLock {
            self.base = base
            self.tilesId = tilesId
        }
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        guard let (base, id) = lock.withLock({ () -> (URL, String)? in
            guard let base, let tilesId else { return nil }
            return (base, tilesId)
        }) else { return result(nil, nil) }
        let url = base.appendingPathComponent(PrecipTypes.tilePath(id, z: path.z, x: path.x, y: path.y))
        URLSession.meteocool.dataTask(with: url) { data, response, error in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data, let grey = GreyPNG.decode(data),
                  let image = PrecipTypes.colour(width: grey.width, height: grey.height, pixels: grey.pixels) else {
                // Nothing in it, or not there: nothing to draw.
                return result(Self.empty, nil)
            }
            result(UIImage(cgImage: image).pngData(), nil)
        }.resume()
    }

    /// A clear tile, for one with no class in it.
    private static let empty: Data? = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }.pngData()
}

@MainActor
final class PrecipTypesMap: NativeMapFeature {
    private weak var map: NativeMapContext?
    private let overlay = ClassTileOverlay()
    private var added = false
    private var shownId: String?

    func attach(to map: NativeMapContext) {
        self.map = map
    }

    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        guard overlay === self.overlay else { return nil }
        let renderer = MKTileOverlayRenderer(tileOverlay: self.overlay)
        renderer.alpha = PrecipTypes.opacity
        return renderer
    }

    func capabilityDidChange(_ capability: NativeMapModel.Capability) {
        guard let map else { return }
        let wanted = capability == .precipitationTypes
        if wanted != added {
            added = wanted
            if wanted { map.mapView.addOverlay(overlay, level: .aboveRoads) } else { map.mapView.removeOverlay(overlay) }
        }
        if wanted { load() }
    }

    func wake() { if added { load() } }

    func tick() { if added { load() } }

    /// `GET /v3/radar/classification` (404 until a set has rendered).
    private func load() {
        guard let map else { return }
        map.fetch(map.endpoints.api.appendingPathComponent("v3/radar/classification")) { [weak self] data, _ in
            guard let self, let map = self.map, let data, let frame = PrecipTypes.Frame.decode(data) else { return }
            map.model.lastUpdated = Date(timeIntervalSince1970: TimeInterval(frame.processedTime))
            guard frame.tilesId != self.shownId else { return }
            self.shownId = frame.tilesId
            self.overlay.set(base: map.endpoints.tiles, tilesId: frame.tilesId)
            (map.mapView.renderer(for: self.overlay) as? MKTileOverlayRenderer)?.reloadData()
        }
    }
}

// MARK: - Lightning

/// NOAA's CONUS base reflectivity under the strikes; asked only over the US.
final class NOAATileOverlay: MKTileOverlay, @unchecked Sendable {
    init() {
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        maximumZ = 10
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        guard LightningRules.noaaCovers(z: path.z, x: path.x, y: path.y), let url = LightningRules.noaaURL(z: path.z, x: path.x, y: path.y)
        else { return result(nil, nil) }
        URLSession.meteocool.dataTask(with: url) { data, response, error in
            result((response as? HTTPURLResponse)?.statusCode == 200 ? data : nil, error)
        }.resume()
    }
}

/// The strikes after the tile set's newest, drawn as core's crosses.
final class StrikeOverlay: NSObject, MKOverlay, @unchecked Sendable {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    private let lock = NSLock()
    private var current: [(point: MKMapPoint, ms: Double)] = []

    var strikes: [(point: MKMapPoint, ms: Double)] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// A "+" of radius 8 pt and stroke 3 in the strike's age colour,
    /// newer over older (`crossFactory`).
    static func draw(_ strikes: [(point: MKMapPoint, ms: Double)], in mapRect: MKMapRect, zoomScale: MKZoomScale, context: CGContext) {
        let px = 1 / Double(zoomScale)
        let r = 8 * px
        let area = mapRect.insetBy(dx: -2 * r, dy: -2 * r)
        let now = Date().timeIntervalSince1970 * 1000
        let visible = strikes.filter { area.contains($0.point) }
            .map { (point: $0.point, style: LightningRules.cross(ageMilliseconds: now - $0.ms)) }
            .sorted { $0.style.z < $1.style.z }
        context.setLineWidth(3 * px)
        context.setLineCap(.butt)
        for strike in visible {
            let rgb = strike.style.rgb
            context.setStrokeColor(UIColor(red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1).cgColor)
            let c = strike.point
            context.move(to: CGPoint(x: c.x - r, y: c.y))
            context.addLine(to: CGPoint(x: c.x + r, y: c.y))
            context.move(to: CGPoint(x: c.x, y: c.y - r))
            context.addLine(to: CGPoint(x: c.x, y: c.y + r))
            context.strokePath()
        }
    }
}

final class StrikeRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? StrikeOverlay else { return }
        StrikeOverlay.draw(overlay.strikes, in: mapRect, zoomScale: zoomScale, context: context)
    }
}

/// The lightning map: the hour's strikes from the tile set, the ones since
/// from the backfill and the socket, the radar faint underneath, NOAA's
/// over the US, and the histogram of the view above the bar.
@MainActor
final class LightningMap: NativeMapFeature {
    private weak var map: NativeMapContext?
    private let tiles = VectorTileOverlay(maxZoom: 9) { tile, zoomScale, context in
        var strikes: [(point: MKMapPoint, ms: Double)] = []
        for layer in tile.layers {
            for feature in layer.features where feature.type == .point {
                guard let seconds = feature.properties["time_wall"]?.number else { continue }
                for part in tile.points(feature, extent: layer.extent) {
                    for point in part { strikes.append((MKMapPoint(x: point.x, y: point.y), seconds * 1000)) }
                }
            }
        }
        StrikeOverlay.draw(strikes, in: tile.rect, zoomScale: zoomScale, context: context)
    }
    private let live = StrikeOverlay()
    private let noaa = NOAATileOverlay()
    private var book = LightningRules.StrikeBook()
    private var layer: LightningRules.Layer?
    private var added = false
    private var batch: Timer?
    private var redraw: Timer?
    let chart = LightningChartState()
    private var chartHost: UIView?
    private var statsToken = 0

    func attach(to map: NativeMapContext) {
        self.map = map
        tiles.onTile = { [weak self] rect in
            guard let self, let map = self.map else { return }
            map.mapView.renderer(for: self.tiles)?.setNeedsDisplay(rect)
        }
        let host = map.addToDock(LightningChartStrip(state: chart))
        host.isHidden = true
        chartHost = host
        chart.dismiss = { [weak self] in
            self?.chart.dismissed = true
            self?.updateChart()
        }
    }

    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        if overlay === tiles { return VectorTileRenderer(overlay: overlay) }
        if overlay === live { return StrikeRenderer(overlay: overlay) }
        if overlay === noaa {
            let renderer = MKTileOverlayRenderer(tileOverlay: noaa)
            renderer.alpha = 0.75
            return renderer
        }
        return nil
    }

    func capabilityDidChange(_ capability: NativeMapModel.Capability) {
        guard let map else { return }
        let wanted = capability == .lightning
        if wanted != added {
            added = wanted
            if wanted {
                map.mapView.addOverlay(noaa, level: .aboveRoads)
                map.mapView.addOverlay(tiles, level: .aboveLabels)
                map.mapView.addOverlay(live, level: .aboveLabels)
                // The rain under the strikes is the newest picture.
                map.player.showLive()
                chart.dismissed = false
                startRedraw()
            } else {
                map.mapView.removeOverlays([noaa, tiles, live])
                redraw?.invalidate()
                redraw = nil
            }
        }
        if wanted { load(backfill: true) }
        updateChart()
    }

    func wake() { if added { load(backfill: true) } }

    func tick() { if added { load(backfill: false) } }

    func regionDidChange() { if added { stats() } }

    func didTap(at coordinate: CLLocationCoordinate2D, point: CGPoint) -> Bool {
        // A tap on the map brings a hidden histogram back (`mapTapped`).
        if added, chart.dismissed {
            chart.dismissed = false
            updateChart()
        }
        return false
    }

    func socketEvent(_ name: String, _ data: Data) {
        guard added, name == "lightning", let strike = LightningRules.live(data) else { return }
        book.add([strike])
        guard batch == nil else { return }
        // In half-second batches, as core coalesces them.
        batch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.batch = nil
                self?.publish()
            }
        }
    }

    /// `GET /v3/lightning/layer`; a new set, then the strikes since its newest.
    private func load(backfill: Bool) {
        guard let map else { return }
        map.fetch(map.endpoints.api.appendingPathComponent("v3/lightning/layer")) { [weak self] data, _ in
            guard let self, let map = self.map, let data, let layer = LightningRules.Layer.decode(data) else { return }
            map.model.lastUpdated = Date(timeIntervalSince1970: TimeInterval(layer.processedTime))
            let fresh = layer.tileId != self.layer?.tileId
            self.layer = layer
            if fresh {
                self.tiles.urlTemplate = map.endpoints.tiles.appendingPathComponent("meteoradar/\(layer.tileId)").absoluteString + "/{z}/{x}/{y}.pbf"
                map.mapView.renderer(for: self.tiles)?.setNeedsDisplay()
            }
            if fresh || backfill { self.backfill(layer) }
        }
        stats()
    }

    private func backfill(_ layer: LightningRules.Layer) {
        guard let map else { return }
        let baseline = LightningRules.baseline(mostRecentStrike: layer.mostRecentStrike, now: Date())
        book.setBaseline(seconds: baseline)
        var components = URLComponents(url: map.endpoints.api.appendingPathComponent("v3/lightning/baseline"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "baseline", value: String(baseline))]
        guard let url = components.url else { return }
        map.fetch(url) { [weak self] data, _ in
            guard let self, let data, let strikes = LightningRules.backfill(data) else { return }
            self.book.add(strikes)
            self.publish()
        }
        publish()
    }

    private func publish() {
        book.prune(now: Date())
        live.strikes = book.strikes.values.map { strike in
            let coordinate = WebMercator.coordinate(x: strike.x, y: strike.y)
            return (MKMapPoint(coordinate), strike.milliseconds)
        }
        map?.mapView.renderer(for: live)?.setNeedsDisplay()
    }

    /// The crosses change colour as they age: redrawn every half minute.
    private func startRedraw() {
        redraw?.invalidate()
        redraw = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let map = self.map else { return }
                map.mapView.renderer(for: self.live)?.setNeedsDisplay()
                map.mapView.renderer(for: self.tiles)?.setNeedsDisplay()
            }
        }
    }

    // MARK: Histogram

    /// The strikes in view per minute over the last half hour (`/v3/lightning/stats`).
    private func stats() {
        guard let map, added, let extent = StormStore.extent(of: map.mapView.visibleMapRect) else { return }
        statsToken += 1
        let mine = statsToken
        chart.loading = chart.bins == nil
        var components = URLComponents(url: map.endpoints.api.appendingPathComponent("v3/lightning/stats"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "bbox", value: LightningRules.statsRing(minLon: extent.west, minLat: extent.south,
                                                                                             maxLon: extent.east, maxLat: extent.north))]
        guard let url = components.url else { return }
        map.fetch(url) { [weak self] data, _ in
            guard let self, mine == self.statsToken else { return }
            self.chart.loading = false
            if let data, let bins = LightningRules.bins(data) {
                self.chart.bins = bins
                self.chart.unavailable = false
            } else {
                self.chart.bins = nil
                self.chart.unavailable = true
            }
        }
        let centre = map.mapView.centerCoordinate
        let language = CoreStrings.language
        let zoom = map.zoomLevel
        Task { [weak self] in
            let name = await ReverseGeocoder.shared.name(latitude: centre.latitude, longitude: centre.longitude, language: language,
                                                         scale: GeocodeScale.forZoom(zoom))
            guard let self, mine == self.statsToken else { return }
            self.chart.place = name
        }
        updateChart()
    }

    private func updateChart() {
        guard let chartHost, let map else { return }
        chart.dark = map.model.isDark
        let wanted = added && !chart.dismissed
        if chartHost.isHidden == wanted {
            UIView.animate(withDuration: 0.2) {
                chartHost.isHidden = !wanted
                chartHost.alpha = wanted ? 1 : 0
                chartHost.invalidateIntrinsicContentSize()
                chartHost.superview?.layoutIfNeeded()
            }
        }
    }
}

/// What the histogram strip shows.
@MainActor
final class LightningChartState: ObservableObject {
    @Published var bins: [Int]?
    @Published var loading = true
    @Published var unavailable = false
    @Published var place: String?
    @Published var dismissed = false
    @Published var dark = false
    var dismiss: () -> Void = {}
}

/// "Lightning in Freising": strikes in view per minute, the last half hour,
/// each bar in the colour a strike that old has on the map.
struct LightningChartStrip: View {
    @ObservedObject var state: LightningChartState

    var body: some View {
        let theme = ChromeTheme(dark: state.dark)
        let title = state.place.map { CoreStrings.t("lightning_in", ["place": $0]) } ?? CoreStrings.t("lightning_in_view")
        ZStack {
            Color.clear.frame(height: ChromeTheme.stripHeight)
            DismissableStrip(title: title, theme: theme, dismiss: state.dismiss) {
                content(theme)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("nativeMap.lightningChart")
        }
        .padding(.horizontal, ChromeTheme.gutter)
    }

    @ViewBuilder
    private func content(_ theme: ChromeTheme) -> some View {
        if state.loading {
            ChartSkeleton(bars: LightningRules.bins).frame(height: 48)
        } else if let bins = state.bins, bins.contains(where: { $0 > 0 }) {
            bars(bins, theme)
        } else {
            Text(CoreStrings.t(state.unavailable ? "lightning_unavailable" : "lightning_none"))
                .scaledFont(12, relativeTo: .caption).foregroundStyle(theme.text2)
        }
    }

    private func bars(_ bins: [Int], _ theme: ChromeTheme) -> some View {
        let peak = max(1, bins.max() ?? 1)
        let height: CGFloat = 34
        return HStack(alignment: .top, spacing: 6) {
            // The y axis at its ends only (`yTickLabel`).
            VStack(alignment: .trailing, spacing: 0) {
                Text(String(peak)).scaledFont(9, relativeTo: .caption2, digits: true)
                Spacer(minLength: 0)
                Text("0").scaledFont(9, relativeTo: .caption2, digits: true)
            }
            .foregroundStyle(theme.text3)
            .frame(height: height)
            VStack(spacing: 2) {
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(Array(bins.enumerated()), id: \.offset) { index, count in
                        let rgb = LightningRules.barColors[index]
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255))
                            .frame(height: max(count > 0 ? 2 : 0, height * CGFloat(count) / CGFloat(peak)))
                    }
                }
                .frame(height: height, alignment: .bottom)
                HStack {
                    Text("-30 min")
                    Spacer()
                    Text("-15 min")
                    Spacer()
                    Text(CoreStrings.t("now"))
                }
                .scaledFont(9, relativeTo: .caption2)
                .foregroundStyle(theme.text3)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(CoreStrings.t("lightning_in_view"))
        .accessibilityValue("\(bins.reduce(0, +))")
    }
}

// MARK: - The bar

/// Where the radar's tray is on the other flat maps: the legend, and how old
/// the picture is (`BottomToolbar.svelte`).
struct OtherMapTray: View {
    @ObservedObject var model: NativeMapModel

    private var theme: ChromeTheme { ChromeTheme(dark: model.isDark) }

    var body: some View {
        // Never empty: a host laid out at zero size does not grow back.
        ZStack {
            Color.clear.frame(height: 1)
            switch model.capability {
            case .precipitationTypes: bar { precipTypes }
            case .lightning: bar { LightningLegend(theme: theme) }
            default: EmptyView()
            }
        }
        .environment(\.colorScheme, theme.colorScheme)
    }

    private func bar(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .chromeGlass(theme, in: RoundedRectangle(cornerRadius: ChromeTheme.trayRadius, style: .continuous))
            // A container: its own children keep their identifiers.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("nativeMap.otherTray")
    }

    private var precipTypes: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                // Two lines, as core breaks it.
                Text(CoreStrings.plain("chrome.scales.precipitation_types"))
                    .scaledFont(11, weight: .semibold, relativeTo: .caption2)
                    .foregroundStyle(theme.text2)
                    .lineLimit(2)
                    .fixedSize()
                HStack(spacing: 0) {
                    ForEach(PrecipTypes.legend, id: \.key) { entry in
                        VStack(spacing: 3) {
                            Rectangle()
                                .fill(Color(red: Double(entry.rgb >> 16 & 0xFF) / 255, green: Double(entry.rgb >> 8 & 0xFF) / 255,
                                            blue: Double(entry.rgb & 0xFF) / 255).opacity(PrecipTypes.opacity))
                                .frame(height: 8)
                            Text(CoreStrings.t(entry.key)).scaledFont(9, relativeTo: .caption2).foregroundStyle(theme.text2).lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            LastUpdatedLabel(date: model.lastUpdated, theme: theme)
        }
    }
}

/// The lightning legend: age colours, labelled at core's minutes.
struct LightningLegend: View {
    let theme: ChromeTheme

    var body: some View {
        VStack(spacing: 4) {
            LinearGradient(colors: stride(from: 0, to: LightningRules.colors.count, by: 6).map { i in
                let rgb = LightningRules.colors[i]
                return Color(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
            }, startPoint: .leading, endPoint: .trailing)
            .frame(height: 8)
            .clipShape(Capsule())
            HStack {
                ForEach(LightningRules.legendMinutes, id: \.self) { minutes in
                    Text(String(minutes)).scaledFont(10, relativeTo: .caption2, digits: true).foregroundStyle(theme.text2)
                    if minutes != LightningRules.legendMinutes.last { Spacer(minLength: 0) }
                }
            }
            Text(CoreStrings.t("chrome.scales.minutes", ["count": 2])).scaledFont(10, relativeTo: .caption2).foregroundStyle(theme.text3)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Last updated 2 minutes ago", beside a ring that empties over five minutes.
struct LastUpdatedLabel: View {
    let date: Date?
    let theme: ChromeTheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            if let date {
                let relative = RelativeDateTimeFormatter.mc.localizedString(for: date, relativeTo: context.date)
                HStack(spacing: 6) {
                    Circle()
                        .trim(from: 0, to: PrecipTypes.freshness(age: context.date.timeIntervalSince(date)) / 100)
                        .stroke(theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .background(Circle().stroke(theme.tint, lineWidth: 2.5))
                        .frame(width: 12, height: 12)
                    Text(PrecipTypes.lastUpdated(relative, prefix: CoreStrings.t("last_updated")))
                        .scaledFont(12, weight: .medium, relativeTo: .caption)
                        .foregroundStyle(theme.text2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("nativeMap.lastUpdated")
            }
        }
    }
}

extension RelativeDateTimeFormatter {
    @MainActor static let mc: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: CoreStrings.language)
        formatter.unitsStyle = .full
        return formatter
    }()
}

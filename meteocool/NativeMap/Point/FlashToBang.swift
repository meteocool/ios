//
//  FlashToBang.swift
//  meteocool
//
//  Flash to bang, on the lightning map and over the radar with lightning
//  on: a tap at the flash, a tap at the thunder, the distance from the gap,
//  and the strike in the live feed it was, ringed on the map.
//

import Combine
import MapKit
import SwiftUI
import UIKit

/// What the button and the panel show.
@MainActor
final class FlashToBangState: ObservableObject {
    @Published var session = FlashToBangRules.Session()
    @Published var open = false
    /// A position to measure from is known.
    @Published var located = false
    @Published var dark = false
    var toggle: () -> Void = {}
    var tap: () -> Void = {}
    var close: () -> Void = {}
    var showStrike: () -> Void = {}
}

/// The count and its search: taps, the clock, the user's position and the
/// strikes from the socket go into `FlashToBangRules.Session`; the match
/// comes back as a ring and a line on the map.
@MainActor
final class FlashToBang: NativeMapFeature {
    private weak var map: NativeMapContext?
    let state = FlashToBangState()
    private var button: UIView?
    private var panel: UIView?
    /// The strikes round the user since the panel opened, by time in milliseconds.
    private var strikes: [Int64: FlashToBangRules.Strike] = [:]
    private let ring = MatchedStrikeAnnotation()
    private var ringShown = false
    private var line: MKPolyline?
    private var clock: Task<Void, Never>?
    private var lastTick: TimeInterval = 0
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private var observers = Set<AnyCancellable>()

    func attach(to map: NativeMapContext) {
        self.map = map
        map.mapView.register(MatchedStrikeView.self, forAnnotationViewWithReuseIdentifier: MatchedStrikeView.reuse)
        state.toggle = { [weak self] in self?.toggle() }
        state.tap = { [weak self] in self?.tap() }
        state.close = { [weak self] in self?.close() }
        state.showStrike = { [weak self] in self?.showStrike() }

        // Under the logo, in the app's left column.
        let button = map.addChrome(FlashToBangButton(state: state))
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: map.view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            button.topAnchor.constraint(equalTo: map.view.safeAreaLayoutGuide.topAnchor, constant: 12 + 52 + 10),
        ])
        button.isHidden = true
        self.button = button
        let panel = map.addToDock(FlashToBangPanel(state: state))
        panel.isHidden = true
        self.panel = panel

        map.model.$userLocation
            .sink { [weak self] _ in DispatchQueue.main.async { self?.locate() } }
            .store(in: &observers)
        map.model.$isDark
            .sink { [weak self] dark in self?.state.dark = dark }
            .store(in: &observers)
        Publishers.CombineLatest(map.model.$covers, map.model.$trayHidden)
            .sink { [weak self] _, _ in DispatchQueue.main.async { self?.updateOffer() } }
            .store(in: &observers)
        // The result grows the panel: measured again, or it spills over the bars under it.
        state.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.panel?.invalidateIntrinsicContentSize() } }
            .store(in: &observers)
    }

    func settingsDidChange() { updateOffer() }

    func capabilityDidChange(_ capability: NativeMapModel.Capability) { updateOffer() }

    /// A count does not survive the background; a result does.
    func stop() {
        if case .counting = state.session.phase { state.session.reset() }
    }

    /// Offered on the lightning map, and over the radar while it draws lightning.
    private func updateOffer() {
        guard let map else { return }
        let capability = map.model.capability
        let offered = (capability == .lightning || capability == .radar && map.isOn(.lightning)) && !map.model.trayHidden
        button?.isHidden = !offered || !map.model.covers.isEmpty
        if !offered, state.open { close() }
    }

    // MARK: - The panel

    private func toggle() {
        if state.open { close() } else { open() }
    }

    private func open() {
        state.open = true
        strikes = [:]
        locate()
        light.prepare()
        updatePanel()
        if let panel { UIAccessibility.post(notification: .screenChanged, argument: panel) }
    }

    private func close() {
        state.open = false
        state.session.reset()
        clock?.cancel()
        clock = nil
        strikes = [:]
        hideMatch()
        updatePanel()
    }

    private func updatePanel() {
        guard let panel else { return }
        let wanted = state.open
        guard panel.isHidden == wanted else { return }
        UIView.animate(withDuration: 0.2) {
            panel.isHidden = !wanted
            panel.alpha = wanted ? 1 : 0
            panel.invalidateIntrinsicContentSize()
            panel.superview?.layoutIfNeeded()
        }
    }

    /// Where the user is: the location button's fix, else Core Location's
    /// last one if recent.
    private func place() -> FlashToBangRules.Place? {
        guard let location = map?.model.userLocation ?? SharedLocationUpdater.getCurrentLocation(),
              location.horizontalAccuracy >= 0 else { return nil }
        return FlashToBangRules.Place(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                      accuracy: location.horizontalAccuracy)
    }

    private func locate() {
        let located = place() != nil
        if state.located != located { state.located = located }
    }

    // MARK: - The count

    private func tap() {
        guard let place = place() else {
            state.located = false
            return
        }
        let now = Date().timeIntervalSince1970
        switch state.session.tap(now: now, place: place) {
        case .flash:
            light.impactOccurred()
            medium.prepare()
            hideMatch()
            startClock()
            #if DEBUG
            echo(flash: now, place: place)
            #endif
        case .bang:
            medium.impactOccurred()
            update()
        case .ignored:
            break
        }
    }

    /// Whether the clock still matters: a count running, or a search.
    private var running: Bool {
        switch state.session.phase {
        case .counting: return true
        case .measured(let measurement): return measurement.searching
        case .idle, .tooFar: return false
        }
    }

    /// Twice a second while a count or a search runs, for their ends.
    private func startClock() {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.update()
                if !self.running { return }
            }
        }
    }

    /// The session against the clock and the strikes so far; a strike
    /// found is ringed, with a success tap the first time.
    private func update() {
        let now = Date().timeIntervalSince1970
        strikes = strikes.filter { now - $0.value.time <= FlashToBangRules.keepFor }
        let before = state.session.measurement?.match
        guard state.session.update(now: now, strikes: Array(strikes.values)),
              let measurement = state.session.measurement, let match = measurement.match, match != before else { return }
        if before == nil { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        showMatch(match, from: measurement.place)
    }

    /// A strike from the socket, kept while the panel is open if it is near
    /// enough to matter; one within 10 km ticks.
    func socketEvent(_ name: String, _ data: Data) {
        guard state.open, name == "lightning", let live = LightningRules.live(data) else { return }
        let coordinate = WebMercator.coordinate(x: live.x, y: live.y)
        receive(FlashToBangRules.Strike(latitude: coordinate.latitude, longitude: coordinate.longitude, time: live.milliseconds / 1000))
    }

    private func receive(_ strike: FlashToBangRules.Strike) {
        guard let place = place() else { return }
        let distance = FlashToBangRules.metres(from: place, to: strike)
        guard distance <= FlashToBangRules.keepWithin else { return }
        strikes[Int64((strike.time * 1000).rounded())] = strike
        let now = Date().timeIntervalSince1970
        if distance <= FlashToBangRules.tickWithin, now - strike.time < 60, now - lastTick > 0.2 {
            lastTick = now
            light.impactOccurred(intensity: 0.6)
        }
        if running { update() }
    }

    #if DEBUG
    /// For UI tests, `MC_FLASH_BANG_STRIKE='2000,270'`: a strike that far
    /// and that way from the user, half a second before each flash, comes
    /// in two seconds after it, as the feed's would.
    private func echo(flash: TimeInterval, place: FlashToBangRules.Place) {
        guard let spec = ProcessInfo.processInfo.environment["MC_FLASH_BANG_STRIKE"]?.split(separator: ","), spec.count == 2,
              let metres = Double(spec[0]), let bearing = Double(spec[1]) else { return }
        let point = FlashToBangRules.destination(from: place, metres: metres, bearing: bearing)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.receive(FlashToBangRules.Strike(latitude: point.latitude, longitude: point.longitude, time: flash - 0.5))
        }
    }
    #endif

    // MARK: - On the map

    private func showMatch(_ match: FlashToBangRules.Match, from place: FlashToBangRules.Place) {
        guard let mapView = map?.mapView else { return }
        let strike = CLLocationCoordinate2D(latitude: match.strike.latitude, longitude: match.strike.longitude)
        ring.coordinate = strike
        if !ringShown {
            ringShown = true
            mapView.addAnnotation(ring)
        }
        if let line { mapView.removeOverlay(line) }
        let user = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        let next = MKPolyline(coordinates: [user, strike], count: 2)
        line = next
        mapView.addOverlay(next, level: .aboveLabels)
    }

    private func hideMatch() {
        guard let mapView = map?.mapView else { return }
        if ringShown {
            ringShown = false
            mapView.removeAnnotation(ring)
        }
        if let line { mapView.removeOverlay(line) }
        line = nil
    }

    /// The user and the strike in view, clear of the panel and the bars.
    private func showStrike() {
        guard let map, let measurement = state.session.measurement, let match = measurement.match else { return }
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: measurement.place.latitude, longitude: measurement.place.longitude))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: match.strike.latitude, longitude: match.strike.longitude))
        var rect = MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        let least = 2_000 * MKMapPointsPerMeterAtLatitude(measurement.place.latitude)
        rect = rect.insetBy(dx: -max(0, least - rect.width) / 2, dy: -max(0, least - rect.height) / 2)
        // MapKit adds the map's own margins (the tray's, kept for Apple's
        // logo) to the padding: only what the panel covers beyond them.
        let mapView = map.mapView
        let top = panel.map { $0.convert($0.bounds, to: mapView).minY } ?? mapView.bounds.maxY
        let covered = mapView.bounds.maxY - top - mapView.layoutMargins.bottom
        let padding = UIEdgeInsets(top: 60, left: ChromeTheme.controlColumn, bottom: max(24, covered + 24), right: ChromeTheme.controlColumn)
        mapView.setVisibleMapRect(rect, edgePadding: padding, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        guard let line, overlay === line else { return nil }
        let renderer = MKPolylineRenderer(polyline: line)
        renderer.strokeColor = state.dark ? UIColor.white.withAlphaComponent(0.85) : UIColor.black.withAlphaComponent(0.7)
        renderer.lineWidth = 2
        renderer.lineDashPattern = [6, 5]
        return renderer
    }

    func view(for annotation: MKAnnotation, in mapView: MKMapView) -> MKAnnotationView? {
        annotation === ring ? mapView.dequeueReusableAnnotationView(withIdentifier: MatchedStrikeView.reuse, for: annotation) : nil
    }
}

// MARK: - Text

private enum FlashText {
    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: PointText.local("flash_bang" + (key.isEmpty ? "" : "_" + key)), arguments: args)
    }

    static func number(_ value: Double) -> String {
        FlashToBangRules.decimal(value, language: CoreStrings.language)
    }

    static func km(_ metres: Double) -> String {
        FlashToBangRules.kilometres(metres, language: CoreStrings.language)
    }

    @MainActor static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: CoreStrings.language)
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

// MARK: - Views

/// The disc that opens the panel, under the logo.
struct FlashToBangButton: View {
    @ObservedObject var state: FlashToBangState

    var body: some View {
        let theme = ChromeTheme(dark: state.dark)
        Button(action: state.toggle) {
            Image(systemName: "bolt.badge.clock")
                .scaledFont(20, weight: .medium, relativeTo: .body)
                .foregroundStyle(state.open ? theme.accent : theme.text)
                .frame(width: 52, height: 52)
                .chromeGlass(theme, in: Circle(), interactive: true)
        }
        .buttonStyle(PressScale())
        .environment(\.colorScheme, theme.colorScheme)
        .accessibilityLabel(FlashText.t(""))
        .accessibilityAddTraits(state.open ? .isSelected : [])
        .accessibilityIdentifier("nativeMap.flashBang")
    }
}

/// The panel in the dock: the result, and under it the one target for both
/// taps, which reads "Flash", then "Thunder?" with the seconds running.
struct FlashToBangPanel: View {
    @ObservedObject var state: FlashToBangState

    var body: some View {
        let theme = ChromeTheme(dark: state.dark)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(FlashText.t(""))
                    .scaledFont(13, weight: .bold, relativeTo: .footnote)
                    .foregroundStyle(theme.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: state.close) {
                    Image(systemName: "xmark")
                        .scaledFont(13, weight: .semibold, relativeTo: .footnote)
                        .foregroundStyle(theme.text3)
                        .frame(width: 44, height: 30)
                }
                .accessibilityLabel(CoreStrings.t("close"))
            }
            .padding(.leading, 16)
            report(theme)
                .padding(.horizontal, 16)
            FlashToBangTarget(state: state, theme: theme)
                .padding(.horizontal, 10)
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chromeGlass(theme, in: RoundedRectangle(cornerRadius: ChromeTheme.trayRadius, style: .continuous))
        .padding(.horizontal, ChromeTheme.gutter)
        .environment(\.colorScheme, theme.colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.flashBang.panel")
    }

    @ViewBuilder
    private func report(_ theme: ChromeTheme) -> some View {
        if !state.located, state.session.measurement == nil {
            line(FlashText.t("no_location"), symbol: "location.slash", theme.text2)
        } else {
            switch state.session.phase {
            case .idle, .counting:
                EmptyView()
            case .tooFar:
                line(FlashText.t("too_far"), symbol: "ear", theme.text2)
            case .measured(let measurement):
                result(measurement, theme)
            }
        }
    }

    private func result(_ measurement: FlashToBangRules.Session.Measurement, _ theme: ChromeTheme) -> some View {
        let seconds = FlashText.number(measurement.gap)
        return VStack(alignment: .leading, spacing: 4) {
            if let match = measurement.match {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(FlashText.km(match.distance) + " km " + CoreStrings.t("compass_" + FlashToBangRules.compass8(match.bearing)))
                        .scaledFont(22, weight: .semibold, relativeTo: .title3, digits: true)
                        .foregroundStyle(theme.text)
                    Text("\(Int(match.bearing.rounded()) % 360)°")
                        .scaledFont(15, relativeTo: .subheadline, digits: true)
                        .foregroundStyle(theme.text2)
                    Spacer(minLength: 8)
                    Button(action: state.showStrike) {
                        Label(FlashText.t("show"), systemImage: "scope")
                            .scaledFont(13, weight: .semibold, relativeTo: .footnote)
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(theme.accentTint, in: Capsule())
                            .hitTarget()
                    }
                    .buttonStyle(PressScale())
                    .accessibilityIdentifier("nativeMap.flashBang.show")
                }
                .accessibilityElement(children: .contain)
                Text(FlashText.t("matched", FlashText.clock.string(from: Date(timeIntervalSince1970: match.strike.time)),
                                 FlashText.t(match.quality.rawValue)))
                    .scaledFont(13, relativeTo: .footnote)
                    .foregroundStyle(theme.text2)
                Text(FlashText.t("counted_about", seconds, FlashText.km(measurement.estimate)))
                    .scaledFont(13, relativeTo: .footnote, digits: true)
                    .foregroundStyle(theme.text3)
            } else {
                Text(FlashText.t("about", FlashText.km(measurement.estimate)))
                    .scaledFont(22, weight: .semibold, relativeTo: .title3, digits: true)
                    .foregroundStyle(theme.text)
                Text(FlashText.t("counted", seconds))
                    .scaledFont(13, relativeTo: .footnote, digits: true)
                    .foregroundStyle(theme.text3)
                if measurement.searching {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(FlashText.t("searching")).scaledFont(13, relativeTo: .footnote).foregroundStyle(theme.text2)
                    }
                } else {
                    Text(FlashText.t("no_match")).scaledFont(13, relativeTo: .footnote).foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if measurement.withinStrikingRange {
                line(FlashText.t("shelter"), symbol: "exclamationmark.triangle.fill", theme.red, weight: .semibold)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.flashBang.result")
    }

    private func line(_ text: String, symbol: String, _ colour: Color, weight: Font.Weight = .regular) -> some View {
        Label(text, systemImage: symbol)
            .scaledFont(13, weight: weight, relativeTo: .footnote)
            .foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The one target for both taps. It takes the touch as it lands, not as it
/// lifts, so the time is the tap's; VoiceOver activates it as a button.
private struct FlashToBangTarget: View {
    @ObservedObject var state: FlashToBangState
    let theme: ChromeTheme
    @GestureState private var pressing = false

    /// When the flash was tapped, while the count runs.
    private var flash: TimeInterval? {
        if case .counting(let flash) = state.session.phase { return flash }
        return nil
    }

    var body: some View {
        let flash = flash
        let title = FlashText.t(flash == nil ? "flash" : "thunder")
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: flash == nil ? "bolt.fill" : "ear")
                Text(title)
            }
            .scaledFont(22, weight: .bold, relativeTo: .title2)
            if let flash {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    Text(FlashText.number(max(0, context.date.timeIntervalSince1970 - flash)) + " s")
                        .scaledFont(17, weight: .semibold, relativeTo: .body, digits: true)
                }
            } else {
                Text(FlashText.t("flash_hint")).scaledFont(13, weight: .medium, relativeTo: .footnote)
            }
        }
        .foregroundStyle(flash == nil ? Color.white : Color.black)
        .multilineTextAlignment(.center)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 88)
        .background(flash == nil ? theme.accent : theme.orange, in: RoundedRectangle(cornerRadius: ChromeTheme.trayRadius - 10, style: .continuous))
        .contentShape(Rectangle())
        .scaleEffect(pressing ? 0.97 : 1)
        .animation(.easeOut(duration: 0.12), value: pressing)
        .opacity(state.located ? 1 : 0.4)
        .gesture(DragGesture(minimumDistance: 0).updating($pressing) { _, pressing, _ in pressing = true })
        .onChange(of: pressing) { _, pressed in
            if pressed, state.located { state.tap() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(FlashText.t(flash == nil ? "flash_hint" : "thunder_hint"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if state.located { state.tap() } }
        .accessibilityIdentifier("nativeMap.flashBang.target")
    }
}

//
//  DryOutlook.swift
//  meteocool
//
//  What the weather models say, in the slot above the tray, on a day the
//  radar has nothing for the reader's position (core's `DryOutlook.svelte`
//  and its conditions in `NowcastPlayback.svelte`).
//

import Combine
import CoreLocation
import SwiftUI

/// Whether the strip is up, and what it shows.
@MainActor
final class DryOutlookState: ObservableObject {
    @Published var series: OpenMeteo.HourlySeries?
    @Published var dark = false
    var open: (Int) -> Void = { _ in }
    var dismiss: () -> Void = {}
}

/// Puts the strip in the dock while core would show it.
@MainActor
final class DryOutlookDock {
    private weak var map: NativeMapContext?
    private let state = DryOutlookState()
    private let host: UIView
    private let openCompare: (CLLocationCoordinate2D, Int) -> Void
    private var dismissed = false
    private var unavailable = false
    private var failedAt = Date.distantPast
    private var fetchedFor: String?
    private var observers = Set<AnyCancellable>()

    /// A failed fetch keeps it down until a wake at least this much later.
    static let retry: TimeInterval = 60

    init(map: NativeMapContext, openCompare: @escaping (CLLocationCoordinate2D, Int) -> Void) {
        self.map = map
        self.openCompare = openCompare
        host = map.addToDock(DryOutlookStrip(state: state))
        host.isHidden = true
        state.open = { [weak self] hours in
            guard let self, let at = self.map?.model.userLocation?.coordinate else { return }
            self.openCompare(at, hours)
        }
        state.dismiss = { [weak self] in
            self?.dismissed = true
            self?.update()
        }
        // Anything the conditions read.
        Publishers.MergeMany(map.player.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                             map.model.objectWillChange.map { _ in () }.eraseToAnyPublisher())
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.update() }
            .store(in: &observers)
    }

    /// The radar has no rain for the reader's own position.
    private var dryAtUser: Bool {
        guard let map, map.model.point == nil else { return false }
        return Dryness.isDry(map.player.timeline.dbz.values.map { Optional($0) })
    }

    private var showable: Bool {
        guard let map, let location = map.model.userLocation?.coordinate else { return false }
        let player = map.player
        return dryAtUser
            && RadarExtents.covers(latitude: location.latitude, longitude: location.longitude)
            && map.model.point == nil
            && map.model.capability == .radar
            && !player.outOfRadar
            && !map.model.stale
            && !unavailable
            // The drawer it opens covers it, and the strip would only restate it.
            && !map.model.compareOpen
            && map.model.selectedStorm == nil
            && player.isLive
            && !player.playing
    }

    func update() {
        guard let map else { return }
        if !dryAtUser { dismissed = false }
        let wanted = showable && !dismissed
        state.dark = map.model.isDark
        if wanted, let location = map.model.userLocation?.coordinate { fetch(location) }
        if host.isHidden == wanted {
            UIView.animate(withDuration: 0.2) {
                self.host.isHidden = !wanted
                self.host.alpha = wanted ? 1 : 0
                self.host.superview?.layoutIfNeeded()
            }
        }
    }

    private func fetch(_ location: CLLocationCoordinate2D) {
        let key = OpenMeteo.hourlyKey(latitude: location.latitude, longitude: location.longitude, variable: SpreadSpec.rainfall.variable)
        guard key != fetchedFor else { return }
        fetchedFor = key
        Task {
            do {
                state.series = try await OpenMeteoClient.shared.hourly(latitude: location.latitude, longitude: location.longitude,
                                                                        variable: SpreadSpec.rainfall.variable)
            } catch {
                // A hint: an error in its place is noise.
                unavailable = true
                failedAt = Date()
                fetchedFor = nil
                update()
            }
        }
    }

    func wake() {
        if unavailable, Date().timeIntervalSince(failedAt) >= Self.retry { unavailable = false }
        // The answer is ten minutes good; a wake asks again after that.
        fetchedFor = nil
        update()
    }
}

/// The strip: the title says how far off rain is, the small spread shows it,
/// a tap or "All models" opens the whole comparison on the same range.
struct DryOutlookStrip: View {
    @ObservedObject var state: DryOutlookState

    var body: some View {
        let theme = ChromeTheme(dark: state.dark)
        // Never empty: a host laid out at zero size does not grow back.
        ZStack {
            Color.clear.frame(height: ChromeTheme.stripHeight)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                strip(theme, now: context.date)
            }
        }
        .padding(.horizontal, ChromeTheme.gutter)
    }

    private func strip(_ theme: ChromeTheme, now: Date) -> some View {
        let outlook = Outlook.strip(state.series, now: now)
        let title = CoreStrings.t(outlook.title.key, outlook.title.arguments)
        return SwipeDock(action: CoreStrings.t("hide"), theme: theme, tap: { state.open(outlook.hours) }, dismiss: state.dismiss) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .accessibilityIdentifier("nativeMap.outlook.title")
                    Spacer(minLength: 6)
                    Button { state.open(outlook.hours) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chart.xyaxis.line").font(.system(size: 11, weight: .semibold))
                            Text(CoreStrings.t("dry_outlook_link")).font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .foregroundStyle(theme.accent)
                        .background(theme.accentTint, in: Capsule())
                    }
                    .buttonStyle(PressScale())
                    .accessibilityIdentifier("nativeMap.outlook.all")
                    Button(action: state.dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.text3)
                            .frame(width: 36, height: 30)
                    }
                    .accessibilityLabel(CoreStrings.t("close"))
                }
                .padding(.leading, 16)
                .padding(.trailing, 4)
                Group {
                    if let series = state.series {
                        SpreadChart(series: series, from: outlook.from, steps: outlook.hours, spec: .rainfall, compact: true, dark: state.dark)
                    } else {
                        Text(CoreStrings.t("dry_outlook_loading")).font(.system(size: 12)).foregroundStyle(theme.text2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .padding(.top, 8)
            .environment(\.colorScheme, theme.colorScheme)
        }
        .accessibilityIdentifier("nativeMap.outlook")
    }
}

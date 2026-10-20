//
//  StormSheet.swift
//  meteocool
//
//  Where a selected storm is read: on a phone the hint bar above the tray
//  (`StormSelectionHint.svelte`), then a sheet that leaves the map usable
//  (`CellSheet.svelte`); on an iPad a panel in the corner (`App.svelte`'s
//  `.cell-details-panel`).
//

import Combine
import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// Shows the selection's hint bar, sheet or panel as the store says.
@MainActor
final class StormSheet: NSObject, UISheetPresentationControllerDelegate {
    private let store: StormStore
    private weak var map: NativeMapContext?
    private let hint: UIView
    private var sheet: UIViewController?
    private var panel: UIView?
    private var panelHeight: NSLayoutConstraint?
    private var panelOn3d: Bool?
    private var observers = Set<AnyCancellable>()

    /// The sheet's two heights (`CellSheet.svelte`): 40 % of the screen, and
    /// all of it but the status bar and a strip of map.
    static let half = UISheetPresentationController.Detent.Identifier("stormHalf")
    static let full = UISheetPresentationController.Detent.Identifier("stormFull")
    /// The iPad panel's width (`.cell-details-panel`).
    static let panelWidth: CGFloat = 392

    init(store: StormStore, map: NativeMapContext) {
        self.store = store
        self.map = map
        hint = map.addToDock(StormHintBar(store: store, model: map.model))
        hint.isHidden = true
        hint.accessibilityIdentifier = "nativeMap.storm.hintHost"
        super.init()
        map.model.$capability
            .sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }
            .store(in: &observers)
        map.model.$isDark
            .sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }
            .store(in: &observers)
    }

    /// Brings the hint, sheet and panel in line with the selection.
    func update() {
        guard let map else { return }
        // The 3D map opens a storm's details too.
        let radar = map.model.capability == .radar || map.model.capability == .cells3d
        let selected = store.selection != nil && radar
        let wantsHint = selected && !store.details && store.twoStage
        let wantsDetails = selected && store.details
        if hint.isHidden == wantsHint {
            UIView.animate(withDuration: 0.2) {
                self.hint.isHidden = !wantsHint
                self.hint.alpha = wantsHint ? 1 : 0
                // Its content changed while it was hidden: measured again.
                self.hint.invalidateIntrinsicContentSize()
                self.hint.superview?.layoutIfNeeded()
            }
        }
        if wantsDetails, store.twoStage {
            removePanel()
            presentSheet()
        } else if wantsDetails {
            dismissSheet()
            showPanel()
            // Its content changed: measured again, or a panel first laid out
            // before it had any stays at that size.
            DispatchQueue.main.async { [weak self] in self?.panel?.invalidateIntrinsicContentSize() }
        } else {
            dismissSheet()
            removePanel()
        }
    }

    func dismiss() {
        dismissSheet()
        removePanel()
    }

    /// Drops the storm and puts its panel away, then `then`: something else
    /// is opening over the map (the layer switcher), which a selection cannot
    /// outlive.
    func close(then: @escaping () -> Void) {
        store.selection = nil
        removePanel()
        dismissSheet(then: then)
    }

    // MARK: - Phone

    private func details(wide: Bool) -> StormDetailsView {
        StormDetailsView(store: store, wide: wide,
                         newestRadarMs: { [weak self] in
                             (self?.map?.radar.processedTimes.newest).map { Double($0) * 1000 }
                         },
                         close: { [weak self] in self?.close() },
                         share: { [weak self] in self?.share() },
                         openAR: arTarget == nil || map?.host?.arAvailable != true ? nil : { [weak self] in self?.openAR() },
                         on3d: map?.model.capability == .cells3d,
                         openIn3D: map?.model.capability == .cells3d ? nil : { [weak self] in self?.openIn3D() })
    }

    private var retrying = false

    private func presentSheet() {
        guard let map else { return }
        if let sheet {
            // Keep it, new storm or not: the details follow the store.
            (sheet as? UIHostingController<StormSheetRoot>)?.rootView = StormSheetRoot(details: details(wide: false), dark: map.model.isDark)
            return
        }
        let controller = UIHostingController(rootView: StormSheetRoot(details: details(wide: false), dark: map.model.isDark))
        controller.modalPresentationStyle = .pageSheet
        controller.view.backgroundColor = .clear
        controller.view.accessibilityIdentifier = "nativeMap.storm.sheet"
        if let presentation = controller.sheetPresentationController {
            presentation.detents = [
                .custom(identifier: Self.half) { context in context.maximumDetentValue * 0.40 },
                .custom(identifier: Self.full) { [weak map] context in
                    let height = map?.view.bounds.height ?? context.maximumDetentValue
                    let top = map?.view.safeAreaInsets.top ?? 0
                    return min(context.maximumDetentValue, min(height * 0.95, height - top - 60))
                },
            ]
            presentation.selectedDetentIdentifier = Self.half
            // The map stays live under it: another storm can be tapped.
            presentation.largestUndimmedDetentIdentifier = Self.full
            presentation.prefersScrollingExpandsWhenScrolledToEdge = false
            presentation.prefersGrabberVisible = true
            presentation.prefersEdgeAttachedInCompactHeight = true
            presentation.delegate = self
        }
        guard map.host?.presentOverMap(controller) == true else {
            // Something else is up (the demo's notice, a sheet on its way
            // out): tried again shortly, while the details are still wanted.
            guard !retrying else { return }
            retrying = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.retrying = false
                self?.update()
            }
            return
        }
        sheet = controller
        map.model.trayHidden = true
    }

    private func dismissSheet(then: (() -> Void)? = nil) {
        guard let sheet else { then?(); return }
        self.sheet = nil
        map?.model.trayHidden = false
        map?.model.covers.remove("stormSheet")
        if sheet.presentingViewController != nil {
            sheet.dismiss(animated: true, completion: then)
        } else {
            then?()
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === sheet else { return }
        sheet = nil
        map?.model.trayHidden = false
        map?.model.covers.remove("stormSheet")
        store.closeDetails()
    }

    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ controller: UISheetPresentationController) {
        // At full height the sheet hides the app's own buttons as well.
        if controller.selectedDetentIdentifier == Self.full {
            map?.model.covers.insert("stormSheet")
        } else {
            map?.model.covers.remove("stormSheet")
        }
    }

    // MARK: - iPad

    private func showPanel() {
        guard let map else { return }
        // Built again for the other map: the 3D map's panel slices the
        // storm by height where the flat map's cuts it open.
        let on3d = map.model.capability == .cells3d
        if let panel {
            guard panelOn3d != on3d else { return }
            panel.removeFromSuperview()
            self.panel = nil
        }
        panelOn3d = on3d
        let view = map.addChrome(StormPanel(details: details(wide: true), dark: map.model.isDark))
        view.accessibilityIdentifier = "nativeMap.storm.panel"
        let height = view.heightAnchor.constraint(lessThanOrEqualTo: map.view.safeAreaLayoutGuide.heightAnchor, constant: -24)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: map.view.safeAreaLayoutGuide.topAnchor, constant: 12),
            view.trailingAnchor.constraint(equalTo: map.view.safeAreaLayoutGuide.trailingAnchor, constant: -ChromeTheme.controlColumn),
            height,
        ])
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        panelHeight = height
        // Never laid out at nothing: a host measured empty does not grow back.
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        view.alpha = 0
        UIView.animate(withDuration: 0.2) { view.alpha = 1 }
        panel = view
    }

    private func removePanel() {
        guard let panel else { return }
        self.panel = nil
        UIView.animate(withDuration: 0.15, animations: { panel.alpha = 0 }) { _ in panel.removeFromSuperview() }
    }

    // MARK: - Actions

    private func close() {
        dismissSheet()
        store.closeDetails()
    }

    private func share() {
        guard let map else { return }
        let subject = details(wide: false).subject
        let title = CoreStrings.t("share.title_about", ["subject": subject])
        map.shareMap(title: title, source: panel)
    }

    /// The AR view finds the storm by its tracked cell, or its volume.
    private var arTarget: StormTarget? {
        guard let selection = store.selection else { return nil }
        if let code = selection.cell?.code { return .cell(code) }
        if let path = selection.volume?.path { return .volume(path) }
        return nil
    }

    /// The storm on the 3D map, cut open where it stands among its neighbours.
    private func openIn3D() {
        guard let map, let selection = store.selection, let at = StormSelect.positionOf(selection) else { return }
        let step = selection.detail.flatMap { StormSelect.trackerSeries($0).last }
        map.model.focus3D = ThreeDFocus(latitude: at.lat, longitude: at.lon,
                                        areaKm2: selection.volume?.areaKm2 ?? step?.areaKm2 ?? selection.cell?.series.last?.areaKm2,
                                        topM: selection.cell?.echoTopMaxM)
        let from = (map.model.capability, map.mapView.camera.copy() as? MKMapCamera)
        map.setCapability(.cells3d)
        map.model.detour = from
        update()
    }

    private func openAR() {
        let target = arTarget
        dismissSheet { [weak self] in self?.map?.host?.openAR(target) }
        removePanel()
        store.closeDetails()
    }
}

/// The phone sheet's content, in the map's light or dark.
struct StormSheetRoot: View {
    let details: StormDetailsView
    let dark: Bool

    var body: some View {
        details
            .environment(\.colorScheme, dark ? .dark : .light)
            // A UIKit-presented sheet: the fill goes under the content.
            .background(DrawerBackground(dark: dark).ignoresSafeArea())
    }
}

/// The iPad panel: the details in the drawers' glass, as tall as they are
/// up to the screen's height.
private struct StormPanel: View {
    let details: StormDetailsView
    let dark: Bool

    var body: some View {
        let theme = ChromeTheme(dark: dark)
        details
            .frame(width: StormSheet.panelWidth)
            .background(DrawerBackground(dark: dark))
            .clipShape(RoundedRectangle(cornerRadius: ChromeTheme.trayRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ChromeTheme.trayRadius, style: .continuous).stroke(theme.edge.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
            .environment(\.colorScheme, theme.colorScheme)
    }
}

/// "Strong storm · alive for 34 min  [Details ›] ✕": the step between a tap
/// and the details on a phone; the bar itself opens them, a swipe clears.
struct StormHintBar: View {
    @ObservedObject var store: StormStore
    @ObservedObject var model: NativeMapModel

    private var theme: ChromeTheme { ChromeTheme(dark: model.isDark) }

    var body: some View {
        // Never empty: a host laid out at zero size does not grow back.
        ZStack {
            Color.clear.frame(height: 54)
            if let selection = store.selection {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    bar(selection, now: context.date.timeIntervalSince1970 * 1000)
                }
            }
        }
        .padding(.horizontal, ChromeTheme.gutter)
    }

    private func bar(_ selection: StormSelection, now: Double) -> some View {
        let severity = StormSelect.severityOf(selection) ?? 0
        let classed = StormSelect.knowsSeverity(selection)
        let colour = Color(uiColor: StormStyle.colour(severity))
        let storm = selection.summary?.properties
        let cell = selection.cell
        let ended = storm.map { $0.status != "active" } ?? !(cell?.active ?? true)
        let born = storm?.bornAt ?? cell?.firstSeen
        let seen = storm?.lastSeen ?? cell?.lastSeen
        let minutes: Double = {
            guard let born else { return 0 }
            if ended, let seen { return (StormTime.ms(seen) - StormTime.ms(born)) / 60_000 + 5 }
            return (now - StormTime.ms(born)) / 60_000
        }()
        let lived = StormRules.duration(max(0, minutes), { CoreStrings.t($0, $1) })
        let merged = storm.map { $0.status == "merged" } ?? !(cell?.childCodes.isEmpty ?? true)
        let life = !ended ? CoreStrings.t("storm.hint.alive", ["duration": lived])
            : CoreStrings.t(merged ? "storm.hint.superseded" : "storm.hint.ended", ["duration": lived])
        let title = classed ? CoreStrings.t("storm.storm_label.\(StormRules.bandNames[max(0, min(severity, 3))])")
            : CoreStrings.t("storm.storm_label.unclassed")
        let open = { store.details = true }
        return SwipeDock(action: CoreStrings.t("storm.hint.clear_action"), theme: theme, height: 54, strong: true, tap: open,
                         dismiss: { store.selection = nil }) {
            HStack(spacing: 10) {
                Circle().fill(ended ? theme.text3 : colour).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(StormDetailsView.capitalised(title))
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                        .foregroundStyle(theme.text)
                    Text(life).font(.system(size: 12)).foregroundStyle(theme.text2).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: open) {
                    HStack(spacing: 4) {
                        Text(CoreStrings.t("storm.hint.details")).font(.system(size: 13, weight: .semibold))
                        Text("›").font(.system(size: 16)).opacity(0.75)
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 10)
                    .frame(height: 32)
                    .foregroundStyle(colour)
                    .background(colour.opacity(0.14), in: Capsule())
                }
                .buttonStyle(PressScale())
                .accessibilityIdentifier("nativeMap.storm.hint.details")
                Button {
                    withAnimation(.easeIn(duration: 0.2)) { store.selection = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.text3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(CoreStrings.t("storm.hint.clear"))
                .accessibilityIdentifier("nativeMap.storm.hint.clear")
            }
            .padding(.leading, 14)
            .padding(.trailing, 2)
            .frame(maxHeight: .infinity)
        }
        // A container: its own children keep their identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.storm.hint")
    }
}

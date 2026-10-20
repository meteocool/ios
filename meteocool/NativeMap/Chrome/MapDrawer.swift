//
//  MapDrawer.swift
//  meteocool
//
//  core's drawers (`CellSheet.svelte` on a phone, the corner panel on a
//  wider screen) for a panel that is not a storm's: the model comparison.
//

import SwiftUI
import UIKit

/// Shows one SwiftUI panel over the map: on a phone a sheet that leaves the
/// map usable, at 40 % or nearly all of the screen; on an iPad a panel in
/// the top corner. The map's tray goes while a phone's sheet is up.
@MainActor
final class MapDrawer: NSObject, UISheetPresentationControllerDelegate {
    private weak var map: NativeMapContext?
    /// The name this drawer covers the app's controls under.
    private let owner: String
    /// The reader put it away (a swipe down, or the close disc).
    var onClose: (() -> Void)?
    private var sheet: UIHostingController<AnyView>?
    private var panel: UIView?
    private var panelHost: UIHostingController<AnyView>?

    static let half = UISheetPresentationController.Detent.Identifier("drawerHalf")
    static let full = UISheetPresentationController.Detent.Identifier("drawerFull")

    init(map: NativeMapContext, owner: String) {
        self.map = map
        self.owner = owner
    }

    var isOpen: Bool { sheet != nil || panel != nil }

    /// Whether this screen takes the corner panel rather than a sheet.
    var wide: Bool { map?.view.traitCollection.horizontalSizeClass == .regular }

    /// Shows `content`, or swaps it in if the drawer is up; a sheet opens
    /// at full height when `full`.
    func show<Content: View>(_ content: Content, full: Bool) {
        guard let map else { return }
        let dark = map.model.isDark
        if wide {
            let root = AnyView(content
                .frame(width: StormSheet.panelWidth)
                .background(DrawerBackground(dark: dark))
                .clipShape(RoundedRectangle(cornerRadius: ChromeTheme.trayRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ChromeTheme.trayRadius, style: .continuous)
                    .stroke(ChromeTheme(dark: dark).edge.opacity(0.5), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                .environment(\.colorScheme, dark ? .dark : .light))
            if let panelHost {
                panelHost.rootView = root
                return
            }
            let host = UIHostingController(rootView: root)
            host.view.backgroundColor = .clear
            host.sizingOptions = .intrinsicContentSize
            host.view.translatesAutoresizingMaskIntoConstraints = false
            map.view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: map.view.safeAreaLayoutGuide.topAnchor, constant: 12),
                host.view.trailingAnchor.constraint(equalTo: map.view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
                host.view.heightAnchor.constraint(lessThanOrEqualTo: map.view.safeAreaLayoutGuide.heightAnchor, constant: -24),
            ])
            host.view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            host.view.accessibilityIdentifier = "nativeMap.drawer.\(owner)"
            host.view.alpha = 0
            UIView.animate(withDuration: 0.2) { host.view.alpha = 1 }
            panelHost = host
            panel = host.view
            return
        }
        let root = AnyView(content
            .background(DrawerBackground(dark: dark).ignoresSafeArea())
            .environment(\.colorScheme, dark ? .dark : .light))
        if let sheet {
            sheet.rootView = root
            return
        }
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .clear
        controller.modalPresentationStyle = .pageSheet
        controller.view.accessibilityIdentifier = "nativeMap.drawer.\(owner)"
        if let presentation = controller.sheetPresentationController {
            presentation.detents = [
                .custom(identifier: Self.half) { context in context.maximumDetentValue * 0.40 },
                .custom(identifier: Self.full) { [weak map] context in
                    let height = map?.view.bounds.height ?? context.maximumDetentValue
                    let top = map?.view.safeAreaInsets.top ?? 0
                    return min(context.maximumDetentValue, min(height * 0.95, height - top - 60))
                },
            ]
            presentation.selectedDetentIdentifier = full ? Self.full : Self.half
            presentation.largestUndimmedDetentIdentifier = Self.full
            presentation.prefersScrollingExpandsWhenScrolledToEdge = false
            presentation.prefersGrabberVisible = true
            presentation.delegate = self
        }
        guard map.host?.presentOverMap(controller) == true else { return }
        sheet = controller
        map.model.trayHidden = true
        if full { map.model.covers.insert(owner) }
    }

    /// Puts it away without telling `onClose`: the caller asked.
    func close() {
        if let sheet {
            self.sheet = nil
            release()
            if sheet.presentingViewController != nil { sheet.dismiss(animated: true) }
        }
        if let panel {
            self.panel = nil
            panelHost = nil
            UIView.animate(withDuration: 0.15, animations: { panel.alpha = 0 }) { _ in panel.removeFromSuperview() }
        }
    }

    private func release() {
        map?.model.trayHidden = false
        map?.model.covers.remove(owner)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === sheet else { return }
        sheet = nil
        release()
        onClose?()
    }

    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ controller: UISheetPresentationController) {
        if controller.selectedDetentIdentifier == Self.full {
            map?.model.covers.insert(owner)
        } else {
            map?.model.covers.remove(owner)
        }
    }
}

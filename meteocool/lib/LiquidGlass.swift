//
//  LiquidGlass.swift
//  meteocool
//
//  Helpers for Apple's Liquid Glass material (iOS 26).
//

import UIKit

/// Liquid Glass chrome, built on `UIGlassEffect`.
///
/// The app still deploys back to iOS 15, so nothing in here is reachable
/// without an availability check — older systems keep the flat blur and the
/// `TribbleButton` artwork the app shipped with.
///
/// Glass belongs to the navigation layer only: the floating map controls, the
/// status bar backdrop, the forecast readout. The radar map itself is content
/// and never gets a glass treatment.
@MainActor
enum LiquidGlass {
    /// A single glass element.
    ///
    /// Glass cannot sample other glass, so elements that sit next to each other
    /// have to be nested in `container(spacing:)` — ungrouped neighbours each
    /// sample the map instead and drift apart visually.
    @available(iOS 26.0, *)
    static func element(interactive: Bool = true, tint: UIColor? = nil) -> UIVisualEffectView {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = interactive
        effect.tintColor = tint
        let view = UIVisualEffectView(effect: effect)
        view.cornerConfiguration = .capsule()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    /// Groups the glass elements added to its `contentView` into one combined
    /// rendering. Elements closer together than `spacing` merge into each other.
    @available(iOS 26.0, *)
    static func container(spacing: CGFloat) -> UIVisualEffectView {
        let effect = UIGlassContainerEffect()
        effect.spacing = spacing
        let view = UIVisualEffectView(effect: effect)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    /// Deactivates the constraints `owner` holds on `views`.
    ///
    /// Moving a storyboard view into a glass container leaves its old
    /// constraints pointing across the hierarchy; UIKit only complains about
    /// that at layout time, so clear them up front.
    static func dropConstraints(on owner: UIView, referencing views: [UIView]) {
        let dangling = owner.constraints.filter { constraint in
            views.contains { view in
                (constraint.firstItem as? UIView) === view || (constraint.secondItem as? UIView) === view
            }
        }
        NSLayoutConstraint.deactivate(dangling)
    }

    /// How far a sheet's navigation bar has to drop to clear its own corners.
    ///
    /// A presented sheet has a large corner radius on iOS 26, and a bar pinned
    /// flush with its top edge puts the trailing glass button straight into
    /// that arc: the circle rides over the rounded corner and reads as
    /// misaligned. Apple's own sheets start their bar content below the curve.
    @available(iOS 26.0, *)
    static let sheetCornerClearance: CGFloat = 12

    /// Lets `table` scroll underneath `bar` instead of starting below it.
    ///
    /// A glass bar with nothing passing under it renders as a flat slab — the
    /// material only reads as glass when content refracts through it. The
    /// settings screens pin their table to the bar's bottom edge, so re-pin it
    /// to the top of the screen and pay for the bar with content insets
    /// (`inset(_:below:)`, from `viewDidLayoutSubviews`).
    @available(iOS 26.0, *)
    static func float(_ bar: UINavigationBar, over table: UITableView, in owner: UIView) {
        guard let topConstraint = owner.constraints.first(where: {
            ($0.firstItem as? UIView) === table && $0.firstAttribute == .top
        }) else { return }

        topConstraint.isActive = false
        table.topAnchor.constraint(equalTo: owner.topAnchor).isActive = true
        table.contentInsetAdjustmentBehavior = .never
        owner.bringSubviewToFront(bar)

        // The bar itself comes down off the sheet's rounded corners.
        if let barTop = owner.constraints.first(where: {
            ($0.firstItem as? UIView) === bar && $0.firstAttribute == .top
        }) {
            barTop.constant = sheetCornerClearance
        }
    }

    /// Keeps `table`'s content clear of the floating `bar` and of the home
    /// indicator. Cheap enough to call on every layout pass.
    @available(iOS 26.0, *)
    static func inset(_ table: UITableView, below bar: UINavigationBar) {
        let top = bar.frame.maxY
        let bottom = table.superview?.safeAreaInsets.bottom ?? 0
        guard table.contentInset.top != top || table.contentInset.bottom != bottom else { return }

        let wasAtTop = table.contentOffset.y <= -table.contentInset.top + 1
        table.contentInset = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        table.verticalScrollIndicatorInsets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if wasAtTop {
            table.contentOffset.y = -top
        }
    }
}

//
//  LiquidGlass.swift
//  meteocool
//
//  Helpers for Apple's Liquid Glass material (iOS 26).
//

import UIKit

/// Helpers that build Liquid Glass views with `UIGlassEffect`.
///
/// The deployment target is iOS 18, so every call needs an availability
/// check. Before iOS 26 the app keeps the flat blur and the `TribbleButton`
/// artwork.
///
/// Use glass only for the navigation layer: the floating map controls and
/// the status bar backdrop. The radar map is content and gets no glass.
@MainActor
enum LiquidGlass {
    /// Creates a single glass element.
    ///
    /// Glass cannot sample other glass. Put neighbouring elements in a
    /// `container(spacing:)`. Without it, each element samples the map and
    /// the elements look visually separate.
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
    /// constraints pointing across the hierarchy. UIKit reports that only at
    /// layout time, so remove them before moving the view.
    static func dropConstraints(on owner: UIView, referencing views: [UIView]) {
        let dangling = owner.constraints.filter { constraint in
            views.contains { view in
                (constraint.firstItem as? UIView) === view || (constraint.secondItem as? UIView) === view
            }
        }
        NSLayoutConstraint.deactivate(dangling)
    }

    /// Distance a sheet's navigation bar moves down to clear the sheet's
    /// rounded top corners.
    ///
    /// A presented sheet has a large corner radius on iOS 26. A bar flush
    /// with the sheet's top edge places the trailing glass button inside that
    /// curve. The button then overlaps the rounded corner and looks
    /// misaligned. Apple's own sheets start their bar content below the curve.
    @available(iOS 26.0, *)
    static let sheetCornerClearance: CGFloat = 12

    /// Lets `table` scroll under `bar` instead of starting below it.
    ///
    /// A glass bar with no content under it renders as a flat slab. The
    /// material looks like glass only when content refracts through it.
    /// The settings screens pin their table to the bar's bottom edge. This
    /// re-pins the table to the top of the screen. Content insets then keep
    /// rows clear of the bar (`inset(_:below:)`, called from
    /// `viewDidLayoutSubviews`).
    @available(iOS 26.0, *)
    static func float(_ bar: UINavigationBar, over table: UITableView, in owner: UIView) {
        guard let topConstraint = owner.constraints.first(where: {
            ($0.firstItem as? UIView) === table && $0.firstAttribute == .top
        }) else { return }

        topConstraint.isActive = false
        table.topAnchor.constraint(equalTo: owner.topAnchor).isActive = true
        table.contentInsetAdjustmentBehavior = .never
        owner.bringSubviewToFront(bar)

        // Move the bar down, clear of the sheet's rounded corners.
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

//
//  PointMenuView.swift
//  meteocool
//
//  What a hold on the radar map offers: the precipitation at that point,
//  the forecast for it, or a link to it (core's `PointMenu.svelte`).
//

import SwiftUI
import UIKit

/// The menu's state: where it is, what the place is called, what its rows do.
@MainActor
final class PointMenuModel: ObservableObject {
    /// The place's name once known; "At This Location" until then or without one.
    @Published var place: String?
    let placement: PointMenuLayout.Placement
    let shareAvailable: Bool
    let onRadar: () -> Void
    let onForecast: () -> Void
    let onShare: () -> Void
    /// The AR view with a marker on the point; nil where AR is not offered.
    let onAR: (() -> Void)?

    init(placement: PointMenuLayout.Placement, shareAvailable: Bool, onRadar: @escaping () -> Void,
         onForecast: @escaping () -> Void, onShare: @escaping () -> Void, onAR: (() -> Void)? = nil) {
        self.placement = placement
        self.shareAvailable = shareAvailable
        self.onRadar = onRadar
        self.onForecast = onForecast
        self.onShare = onShare
        self.onAR = onAR
    }

    var title: String { place ?? CoreStrings.t("point_menu_title") }
}

/// The menu, its notch and the red dot on the point, as one column: the
/// dot at the bottom when the menu is above the point, on top when it is
/// below; leaning, the dot and notch stay on the point.
struct PointMenuView: View {
    @ObservedObject var menu: PointMenuModel
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var placement: PointMenuLayout.Placement { menu.placement }

    private var alignment: HorizontalAlignment {
        switch placement.side {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    /// The dot and the notch, moved along the leaning edge onto the point.
    private func shift(_ half: Double) -> CGFloat {
        switch placement.side {
        case .left: return CGFloat(placement.lean - half)
        case .center: return 0
        case .right: return -CGFloat(placement.lean - half)
        }
    }

    /// Where it grows from: the dot's end, its leaning side.
    private var anchor: UnitPoint {
        let x: CGFloat = placement.side == .left ? 0 : placement.side == .right ? 1 : 0.5
        return UnitPoint(x: x, y: placement.below ? 0 : 1)
    }

    var body: some View {
        PointGlassGroup {
            VStack(alignment: alignment, spacing: 0) {
                if placement.below {
                    dot
                    notch.padding(.top, 5).padding(.bottom, -1)
                    card
                } else {
                    card
                    notch.padding(.top, -1).padding(.bottom, 5)
                    dot
                }
            }
        }
        .scaleEffect(shown ? 1 : 0.94, anchor: anchor)
        .animation(PointStyle.spring(reduceMotion), value: shown)
        .opacity(shown ? 1 : 0)
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.12), value: shown)
        .onAppear { shown = true }
    }

    private var dot: some View {
        Circle()
            .fill(PointStyle.red)
            .frame(width: 14, height: 14)
            // Red, as a dropped pin is: blue is the user's own position.
            .background(Circle().fill(.white).frame(width: 20, height: 20).shadow(color: .black.opacity(0.35), radius: 3, y: 1))
            .offset(x: shift(PointMenuLayout.dotHalf))
            .accessibilityHidden(true)
    }

    private var notch: some View {
        Color.clear
            .frame(width: 18, height: 9)
            .pointGlass(PointNotch(up: placement.below))
            .offset(x: shift(PointMenuLayout.notchHalf))
            .accessibilityHidden(true)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(menu.title)
                .scaledFont(14, weight: .bold, relativeTo: .subheadline)
                .tracking(-0.14)
                .foregroundStyle(PointStyle.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(EdgeInsets(top: 5, leading: 10, bottom: 7, trailing: 10))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 2) {
                row("drop.fill", "point_menu_precipitation", "point_menu_precipitation_sub", id: "radar", action: menu.onRadar)
                row("chart.xyaxis.line", "point_menu_forecast", "point_menu_forecast_sub", id: "forecast", action: menu.onForecast)
                if menu.shareAvailable {
                    row("square.and.arrow.up", "point_menu_share", "point_menu_share_sub", id: "share", action: menu.onShare)
                }
                // The app's own, not core's: the AR view is only in the app.
                if let onAR = menu.onAR {
                    row("arkit", title: NSLocalizedString("point_menu_ar", comment: ""),
                        subtitle: NSLocalizedString("point_menu_ar_sub", comment: ""), id: "ar", action: onAR)
                }
            }
        }
        .padding(6)
        .frame(minWidth: PointMenuLayout.minWidth, maxWidth: PointMenuLayout.maxWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .pointGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 15, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(menu.title)
        .accessibilityIdentifier("nativeMap.point.menu")
    }

    /// A row with core's strings, by their keys.
    private func row(_ symbol: String, _ label: String, _ sub: String, id: String, action: @escaping () -> Void) -> some View {
        row(symbol, title: CoreStrings.t(label), subtitle: CoreStrings.t(sub), id: id, action: action)
    }

    private func row(_ symbol: String, title: String, subtitle: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .scaledFont(15, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(PointStyle.accent)
                    .frame(width: 32, height: 32)
                    .background(PointStyle.accentTint, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .scaledFont(15, weight: .semibold, relativeTo: .subheadline)
                        .tracking(-0.15)
                        .foregroundStyle(PointStyle.text)
                    Text(subtitle)
                        .scaledFont(12, relativeTo: .caption)
                        .foregroundStyle(PointStyle.text2)
                }
                .lineLimit(1)
            }
        }
        .buttonStyle(PointMenuRowStyle())
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .accessibilityIdentifier("nativeMap.point.\(id)")
    }
}

/// A row: clear at rest, tinted while pressed or hovered.
private struct PointMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(configuration.isPressed ? PointStyle.tintActive : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .hoverEffect(.highlight)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The notch from the card to the dot: down under a card above the point,
/// up over one below it.
struct PointNotch: Shape {
    let up: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if up {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

/// Glass shapes that touch read as one piece of glass on iOS 26.
struct PointGlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 2) { content }
        } else {
            content
        }
    }
}

/// Holds the menu over the map: a tap anywhere else closes it and goes on
/// to whatever it landed on, as core's capture-phase listener does; Escape
/// closes it too.
final class PointMenuOverlay: UIView {
    var onClose: (() -> Void)?
    private(set) var card: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityIdentifier = "nativeMap.point.overlay"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Places the menu's column so the dot's centre is on `point`.
    func place(_ card: UIView, at point: CGPoint, placement: PointMenuLayout.Placement) {
        self.card = card
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        let dot = CGFloat(PointMenuLayout.dotHalf)
        let lean = CGFloat(placement.lean)
        let anchor = placement.below
            ? card.topAnchor.constraint(equalTo: topAnchor, constant: point.y - dot)
            : card.bottomAnchor.constraint(equalTo: topAnchor, constant: point.y + dot)
        // On the point unless that would put it past the safe area: a menu
        // with very large text slides in rather than going under the bars.
        anchor.priority = .defaultHigh
        var constraints = [
            anchor,
            card.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            card.bottomAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ]
        switch placement.side {
        case .left: constraints.append(card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: point.x - lean))
        case .center: constraints.append(card.centerXAnchor.constraint(equalTo: leadingAnchor, constant: point.x))
        case .right: constraints.append(card.trailingAnchor.constraint(equalTo: leadingAnchor, constant: point.x + lean))
        }
        NSLayoutConstraint.activate(constraints)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let card, card.frame.contains(point) { return super.hitTest(point, with: event) }
        // Outside the menu a touch puts it away and goes no further, as a
        // system menu's does: not a tap on a storm or a 3D tag under it too.
        return event?.type == .touches ? self : nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onClose?()
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    @objc private func escape() { onClose?() }

    override func accessibilityPerformEscape() -> Bool {
        onClose?()
        return true
    }
}

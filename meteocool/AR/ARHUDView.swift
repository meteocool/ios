//
//  ARHUDView.swift
//  meteocool
//
//  The controls floating over the AR storm view.
//

import Observation
import SwiftUI

/// What the HUD shows. Written by `ARStormViewController`, read by the view.
@MainActor
@Observable
final class ARHUDModel {
    struct Banner: Equatable {
        var text: String
        var actionTitle: String?
    }

    struct Guidance: Equatable {
        /// Degrees to turn, positive to the right.
        var degrees: Double
        var text: String
    }

    var mode: ARViewMode = .live
    var sliderValue: Double = 0
    var sliderText = ""
    var isPreview = false
    var showLightning = true
    var extrapolate = false
    var status = ""
    var alignment = ""
    /// True azimuth the camera faces, for the compass tape.
    var heading: Double = 0
    var banner: Banner?
    var sunFixArmed = false
    var guidance: Guidance?
    /// Whether the selected storm (or any storm) has a track for the Track mode.
    var trackAvailable = false

    var onClose: () -> Void = {}
    var onModeChange: (ARViewMode) -> Void = { _ in }
    var onSliderChange: (Double) -> Void = { _ in }
    var onToggleLightning: (Bool) -> Void = { _ in }
    var onToggleExtrapolate: (Bool) -> Void = { _ in }
    var onArmSunFix: () -> Void = {}
    var onResetAlignment: () -> Void = {}
    var onBannerAction: () -> Void = {}
}

/// The HUD, in two parts hosted separately: the bar and compass along the
/// top, the mode controls along the bottom.
///
/// Two hosting views sized to their content rather than one over the whole
/// screen: a hosting view takes every touch inside its bounds, including on
/// SwiftUI's own buttons, so a full-screen one either swallows the sky (no
/// storm can be tapped, no drag nudges the overlay) or, let through, swallows
/// the buttons. The sky between the two parts belongs to the scene.
struct ARHUDView: View {
    enum Part {
        case top
        case bottom
    }

    @Bindable var model: ARHUDModel
    let part: Part

    var body: some View {
        VStack(spacing: 10) {
            switch part {
            case .top:
                topBar
                CompassTape(heading: model.heading)
                    .frame(height: 28)
                    .padding(.horizontal, 24)
                    .accessibilityHidden(true)
                if let banner = model.banner {
                    bannerView(banner)
                }
                if model.sunFixArmed {
                    Text("ar_sun_fix_instructions")
                        .font(.callout.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .hudBackground()
                        .accessibilityIdentifier("ar.sunFix")
                }
            case .bottom:
                if let guidance = model.guidance {
                    guidanceView(guidance)
                }
                if let slider = model.mode.slider {
                    sliderRow(slider)
                }
                modePicker
            }
        }
        .padding(.vertical, 8)
        .tint(.white)
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: model.onClose) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .hudBackground(circle: true)
            .accessibilityLabel(Text("ar_close"))
            .accessibilityIdentifier("ar.close")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.status)
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("ar.status")
                Text(model.alignment)
                    .font(.caption)
                    .opacity(0.85)
                    .accessibilityIdentifier("ar.alignment")
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hudBackground()
            .accessibilityElement(children: .combine)

            Menu {
                Toggle(isOn: Binding(get: { model.showLightning }, set: { model.onToggleLightning($0) })) {
                    Label("ar_menu_lightning", systemImage: "bolt.fill")
                }
                Toggle(isOn: Binding(get: { model.extrapolate }, set: { model.onToggleExtrapolate($0) })) {
                    Label("ar_menu_extrapolate", systemImage: "arrow.forward.circle")
                }
                if !model.isPreview {
                    Divider()
                    Button(action: model.onArmSunFix) {
                        Label("ar_menu_sun_fix", systemImage: "sun.max")
                    }
                    Button(action: model.onResetAlignment) {
                        Label("ar_menu_reset_alignment", systemImage: "location.north.line")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .hudBackground(circle: true)
            .accessibilityLabel(Text("ar_menu"))
            .accessibilityIdentifier("ar.menu")
        }
        .padding(.horizontal, 12)
    }

    private func bannerView(_ banner: ARHUDModel.Banner) -> some View {
        HStack(spacing: 10) {
            Text(banner.text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let title = banner.actionTitle {
                Button(title, action: model.onBannerAction)
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("ar.bannerAction")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .hudBackground()
        .padding(.horizontal, 12)
        .accessibilityIdentifier("ar.banner")
    }

    private func guidanceView(_ guidance: ARHUDModel.Guidance) -> some View {
        HStack(spacing: 8) {
            Image(systemName: guidance.degrees < 0 ? "arrow.turn.up.left" : "arrow.turn.up.right")
                .font(.headline)
            Text(guidance.text)
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .hudBackground()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ar.guidance")
    }

    private func sliderRow(_ slider: ARViewMode.Slider) -> some View {
        HStack(spacing: 12) {
            Slider(value: Binding(get: { model.sliderValue }, set: { model.onSliderChange($0) }), in: slider.range)
                .accessibilityIdentifier("ar.slider")
                .accessibilityValue(Text(model.sliderText))
            Text(model.sliderText)
                .font(.footnote.monospacedDigit().weight(.semibold))
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .hudBackground()
        .padding(.horizontal, 12)
    }

    private var modePicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ARViewMode.allCases) { mode in
                        let disabled = mode.needsMotion && !model.trackAvailable
                        Button {
                            model.onModeChange(mode)
                        } label: {
                            Text(mode.title)
                                .font(.subheadline.weight(model.mode == mode ? .bold : .regular))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                        }
                        .disabled(disabled)
                        .opacity(disabled ? 0.45 : 1)
                        .hudBackground(selected: model.mode == mode)
                        .accessibilityIdentifier("ar.mode.\(mode.rawValue)")
                        .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
                        .id(mode)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onChange(of: model.mode) { _, mode in
                withAnimation { proxy.scrollTo(mode, anchor: .center) }
            }
        }
    }
}

/// A strip of compass ticks, centred on the heading.
private struct CompassTape: View {
    let heading: Double

    var body: some View {
        Canvas { context, size in
            let degreesAcross = 90.0
            let perDegree = size.width / degreesAcross
            let start = Int((heading - degreesAcross / 2).rounded(.down))
            for degree in start ... start + Int(degreesAcross) + 1 where degree % 5 == 0 {
                let x = size.width / 2 + (Double(degree) - heading) * perDegree
                let major = degree % 45 == 0
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x, y: size.height - (major ? 10 : 5)))
                context.stroke(path, with: .color(.white.opacity(0.8)), lineWidth: major ? 1.5 : 1)
                if major {
                    let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
                    let name = names[(Int(Geo.normalise(Double(degree))) / 45) % 8]
                    context.draw(Text(name).font(.caption2.weight(.bold)).foregroundColor(.white), at: CGPoint(x: x, y: 6))
                }
            }
            var marker = Path()
            marker.move(to: CGPoint(x: size.width / 2, y: size.height))
            marker.addLine(to: CGPoint(x: size.width / 2, y: size.height - 16))
            context.stroke(marker, with: .color(.yellow), lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
    }
}

private struct HUDBackground: ViewModifier {
    var circle: Bool
    var selected: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if circle {
                content.glassEffect(.regular.interactive(), in: .circle)
            } else {
                // Tinted with the accent, not white: white text on a white
                // tint is unreadable over a bright sky.
                content.glassEffect(selected ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
            }
        } else if circle {
            content.background(.ultraThinMaterial.opacity(0.9), in: Circle())
                .environment(\.colorScheme, .dark)
        } else {
            content.background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.85)) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                .environment(\.colorScheme, .dark)
        }
    }
}

private extension View {
    func hudBackground(circle: Bool = false, selected: Bool = false) -> some View {
        modifier(HUDBackground(circle: circle, selected: selected))
    }
}

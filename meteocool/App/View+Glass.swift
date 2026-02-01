import SwiftUI

struct LiquidGlass: ViewModifier {
    var cornerRadius: CGFloat = 16
    var material: Material = .regular

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(material, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
        }
    }
}

struct LiquidGlassCircle: ViewModifier {
    var material: Material = .regular

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(.regular, in: .circle)
        } else {
            content
                .background(material, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
        }
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 16) -> some View {
        modifier(LiquidGlass(cornerRadius: cornerRadius, material: .regular))
    }

    func liquidGlassThick(cornerRadius: CGFloat = 16) -> some View {
        modifier(LiquidGlass(cornerRadius: cornerRadius, material: .thick))
    }

    func liquidGlassCircle() -> some View {
        modifier(LiquidGlassCircle(material: .regular))
    }

    func liquidGlassCircleThick() -> some View {
        modifier(LiquidGlassCircle(material: .thick))
    }
}

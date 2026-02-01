import SwiftUI

struct LiquidGlass: ViewModifier {
    var cornerRadius: CGFloat = 16
    var material: Material = .regular
    
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(material.interactive(), in: .rect(cornerRadius: cornerRadius))
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
    
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(material.interactive(), in: .circle)
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
    func liquidGlass(cornerRadius: CGFloat = 16, material: Material = .regular) -> some View {
        modifier(LiquidGlass(cornerRadius: cornerRadius, material: material))
    }
    
    func liquidGlassCircle(material: Material = .regular) -> some View {
        modifier(LiquidGlassCircle(material: material))
    }
}

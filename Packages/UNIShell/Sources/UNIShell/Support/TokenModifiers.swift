import SwiftUI
import UNIDesign

extension View {
    /// A divisória de 0.5px que o design usa em toda parte.
    public func hairline(_ color: TokenColor, edges: Edge.Set = .bottom) -> some View {
        overlay(alignment: alignment(for: edges)) {
            Rectangle()
                .fill(color.color)
                .frame(
                    width: edges.contains(.leading) || edges.contains(.trailing) ? 0.5 : nil,
                    height: edges.contains(.top) || edges.contains(.bottom) ? 0.5 : nil
                )
        }
    }

    private func alignment(for edges: Edge.Set) -> Alignment {
        if edges.contains(.top) { return .top }
        if edges.contains(.leading) { return .leading }
        if edges.contains(.trailing) { return .trailing }
        return .bottom
    }
}

/// Rótulo em versalete que o design usa nos cabeçalhos de seção:
/// mono, minúsculo, caixa alta, muito espaçado.
public struct CapsLabel: ViewModifier {
    @Environment(\.theme) private var theme
    let size: CGFloat

    public func body(content: Content) -> some View {
        content
            .font(theme.mono.font(size: size, weight: .medium))
            .tracking(theme.capsTracking(at: size))
            .textCase(.uppercase)
            .foregroundStyle(theme.ink4.color)
    }
}

extension View {
    public func capsLabel(size: CGFloat = 9) -> some View {
        modifier(CapsLabel(size: size))
    }
}

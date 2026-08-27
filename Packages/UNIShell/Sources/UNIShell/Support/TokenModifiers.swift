import SwiftUI
import UNIDesign

/// A divisória de 0.5px que o design usa em toda parte.
///
/// A faixa de 0.5pt precisa **começar num ponto inteiro** para existir: quando
/// ela cai na metade de trás de um pixel, o compositor a apaga. Era o que
/// acontecia nas bordas `trailing` — as divisórias verticais entre barra
/// lateral e lista (x=236) e entre lista e leitor (x=606) não desenhavam nada,
/// enquanto a `leading` da trilha de agenda (x=1178) aparecia. Nas bordas de
/// fim (`trailing` e `bottom`) o traço recua meio ponto para dentro; nas de
/// início (`leading` e `top`) ele já nasce alinhado. Nenhum painel muda de
/// largura por isso.
public enum Hairline {
    /// `0.5px` do protótipo — a espessura de toda divisória do design.
    public static let thickness: CGFloat = 0.5

    /// Quanto o traço recua para dentro do painel, por borda.
    public static func inset(for edges: Edge.Set) -> CGFloat {
        if edges.contains(.top) { return 0 }
        if edges.contains(.leading) { return 0 }
        return -thickness  // .trailing e .bottom
    }

    public static func alignment(for edges: Edge.Set) -> Alignment {
        if edges.contains(.top) { return .top }
        if edges.contains(.leading) { return .leading }
        if edges.contains(.trailing) { return .trailing }
        return .bottom
    }

    public static func isVertical(_ edges: Edge.Set) -> Bool {
        edges.contains(.leading) || edges.contains(.trailing)
    }
}

extension View {
    /// Ver `Hairline`.
    public func hairline(_ color: TokenColor, edges: Edge.Set = .bottom) -> some View {
        let vertical = Hairline.isVertical(edges)
        let inset = Hairline.inset(for: edges)
        return overlay(alignment: Hairline.alignment(for: edges)) {
            Rectangle()
                .fill(color.color)
                .frame(
                    width: vertical ? Hairline.thickness : nil,
                    height: vertical ? nil : Hairline.thickness
                )
                .offset(x: vertical ? inset : 0, y: vertical ? 0 : inset)
        }
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

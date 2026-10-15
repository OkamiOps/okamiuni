import SwiftUI

/// O fundo da janela: o gradiente do tema quando ele tem um, `paper` quando
/// não tem.
///
/// É uma `View` e não um modificador porque ela é literalmente a camada de
/// baixo do shell — fica num `ZStack`, atrás de todos os painéis.
public struct Backdrop: View {
    @Environment(\.theme) private var theme

    public init() {}

    public var body: some View {
        if let backdrop = theme.backdrop {
            GeometryReader { proxy in
                let maior = max(proxy.size.width, proxy.size.height)
                ZStack {
                    backdrop.base.color
                    if !backdrop.stops.isEmpty {
                        LinearGradient(
                            stops: backdrop.stops.map {
                                Gradient.Stop(color: $0.color.color, location: $0.location)
                            },
                            // O ângulo CSS conta de cima no sentido do
                            // relógio: 135° é do canto superior esquerdo para
                            // o inferior direito. `UnitPoint` do SwiftUI tem o
                            // eixo y para baixo, e é por isso que o seno entra
                            // sem inverter sinal.
                            startPoint: Self.unitPoint(degrees: backdrop.angle, start: true),
                            endPoint: Self.unitPoint(degrees: backdrop.angle, start: false)
                        )
                    }
                    // Os halos do tema escuro. Cada um apaga até transparente
                    // a 70% do raio, como no protótipo — sem isso o segundo
                    // halo cobriria o primeiro em vez de se somar a ele.
                    ForEach(Array(backdrop.glows.enumerated()), id: \.offset) { _, glow in
                        RadialGradient(
                            gradient: Gradient(colors: [
                                glow.color.color,
                                glow.color.color.opacity(0),
                            ]),
                            center: glow.center,
                            startRadius: 0,
                            endRadius: maior * glow.radius
                        )
                    }
                }
            }
            .ignoresSafeArea()
        } else {
            theme.paper.color.ignoresSafeArea()
        }
    }

    /// Converte o ângulo do `linear-gradient` do CSS nos dois `UnitPoint` que
    /// o SwiftUI pede.
    public static func unitPoint(degrees: Double, start: Bool) -> UnitPoint {
        let radians = (degrees - 90) * .pi / 180
        let dx = cos(radians) / 2
        let dy = sin(radians) / 2
        return start
            ? UnitPoint(x: 0.5 - dx, y: 0.5 - dy)
            : UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
    }
}

/// Qual dos dois preenchimentos do tema de vidro este painel usa.
public enum GlassPanelKind: Sendable, Hashable {
    /// Navegação e listas: o mais translúcido.
    case pane
    /// O leitor, onde há texto longo: o mais fechado.
    case reader
}

extension View {
    /// Transforma esta `View` num painel flutuante. Em **todos** os temas.
    ///
    /// Antes era só no Vidro: sem `panel` o modificador não fazia nada e os 26
    /// temas antigos ficavam encostados. Agora o painel é a estrutura do shell
    /// — a mesma dos dois Vidros — e o que o tema decide é só com o que ele é
    /// pintado: `theme.resolvedPanel` devolve o vidro translúcido dos dois
    /// temas que o declaram e a caixa opaca de tokens dos outros 26.
    public func glassPanel(
        _ theme: Theme, kind: GlassPanelKind = .pane, fill: Bool = true
    ) -> some View {
        modifier(GlassPanelModifier(theme: theme, kind: kind, fill: fill))
    }
}

struct GlassPanelModifier: ViewModifier {
    let theme: Theme
    let kind: GlassPanelKind
    /// `false` quando o próprio conteúdo já pinta o fundo dele e o painel só
    /// precisa da aresta, da sombra e do recorte.
    let fill: Bool

    func body(content: Content) -> some View {
        let panel = theme.resolvedPanel
        let shape = RoundedRectangle(cornerRadius: panel.radius, style: .continuous)
        return content
            .background(fill ? (kind == .reader ? panel.readerFill : panel.fill).color : .clear)
            .clipShape(shape)
            .overlay {
                // `strokeBorder` desenha para dentro: o fio de luz do
                // protótipo é a aresta interna do vidro, e `stroke` o
                // montaria metade fora do recorte, onde ele desaparece.
                shape.strokeBorder(panel.edge.color, lineWidth: 1)
            }
            .shadow(panel.shadow)
    }
}

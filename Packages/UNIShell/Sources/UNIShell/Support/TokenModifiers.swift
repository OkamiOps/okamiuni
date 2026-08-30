import SwiftUI
import UNIDesign

/// A divisória de um pixel que o design usa em toda parte.
///
/// A faixa precisa **começar num ponto inteiro** para existir: quando ela cai
/// na metade de trás de um pixel, o compositor a apaga. Era o que acontecia
/// nas bordas `trailing` quando a espessura era meio **ponto** cravado — as
/// divisórias verticais entre barra lateral e lista e entre lista e leitor não
/// desenhavam nada. O conserto foi a espessura virar um
/// pixel do dispositivo (`thickness(_:)`): a faixa encostada na borda de fim
/// já nasce alinhada à grade em qualquer escala, e não precisa recuar.
///
/// O recuo de uma espessura que existia aqui era o resto daquela época, e
/// atrasado ele **desalinhava**: o traço ia parar um pixel para dentro do
/// painel, o último pixel voltava a ser o fundo, e a divisória descolava do
/// vizinho. Medido em 1× na barra lateral: x=234 era `--line` e x=235, o
/// último pixel do painel, era `surface2`. Agora a divisória é o último pixel
/// do painel — que é onde o protótipo a encosta. Nenhum painel muda de largura
/// por isso: a faixa é `overlay`, não ocupa lugar no layout.
public enum Hairline {
    /// **Um pixel do dispositivo**, não meio ponto.
    ///
    /// O protótipo escreve `0.5px`. O navegador não desenha meio pixel: em tela
    /// 1× ele arredonda para 1 pixel, e em 2× meio pixel CSS **é** um pixel do
    /// dispositivo. Nos dois casos o design mostra **uma linha cheia de um
    /// pixel** — foi isso que o dono viu ao desenhar.
    ///
    /// Nós desenhávamos 0,5 **ponto** ao pé da letra. Numa tela 1× isso é um
    /// pixel pintado pela metade: a borda sai lavada, e às vezes espalhada em
    /// dois pixels conforme a posição subpixel. Medido na janela real, numa tela
    /// 1×: a borda do botão saía `rgb(227,225,219)` onde o design mostra
    /// `rgb(218,214,206)`. É por isso que as caixas "pareciam não estar
    /// fechadas" e que duas linhas próximas liam como contorno duplo.
    ///
    /// `1 / displayScale` dá exatamente um pixel: 1,0pt em 1×, 0,5pt em 2×.
    public static func thickness(_ displayScale: CGFloat) -> CGFloat {
        displayScale > 0 ? 1 / displayScale : 1
    }

    /// O valor que a função devolve numa tela 2×.
    ///
    /// **Não desenhe com isto.** Nenhum caminho de desenho o usa desde a Task
    /// AC: toda espessura sai de `thickness(_:)`, lida do ambiente. Ele sobrevive
    /// como referência para código que compara medidas sem ter tela por perto —
    /// `PaneDivider.hitWidth`, que dimensiona um alvo de mouse contra a linha
    /// mais fina que o design chega a pintar.
    public static let thickness: CGFloat = 0.5

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
        modifier(HairlineModifier(color: color, edges: edges))
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
            .foregroundStyle(theme.ink3.color)
    }
}

extension View {
    public func capsLabel(size: CGFloat = 9) -> some View {
        modifier(CapsLabel(size: size))
    }
}


/// Ver `Hairline.thickness(_:)` para por que a espessura vem da escala da tela.
private struct HairlineModifier: ViewModifier {
    @Environment(\.displayScale) private var displayScale
    let color: TokenColor
    let edges: Edge.Set

    func body(content: Content) -> some View {
        let vertical = Hairline.isVertical(edges)
        let thickness = Hairline.thickness(displayScale)
        // Sem deslocamento: o alinhamento do `overlay` já encosta a faixa na
        // borda pedida, e é ali que ela tem de ficar — o último pixel do painel
        // é a divisória. Ver `Hairline`.
        return content.overlay(alignment: Hairline.alignment(for: edges)) {
            Rectangle()
                .fill(color.color)
                .frame(
                    width: vertical ? thickness : nil,
                    height: vertical ? nil : thickness
                )
        }
    }
}

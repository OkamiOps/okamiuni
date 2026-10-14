import SwiftUI

/// Os valores literais do shell **Vidro**, copiados do protótipo
/// `Caixa-Vidro-Final.dc.html` / `Sidebar.dc.html`.
///
/// Eles não moram em `design/tokens.json` porque não são tokens planos de CSS:
/// um gradiente de três paradas e dois halos radiais não cabem numa única
/// string de cor, e o gerador teria de aprender uma segunda gramática só para
/// dois temas. O precedente é o mesmo das cores do design system Okami, que já
/// vivem escritas em Swift em `Theme.swift`.
///
/// O gerador **referencia** estas constantes: `Themes+Generated.swift` recebe
/// `backdrop: .vidroClaro` para o tema `vidro` e `.vidroNoite` para o escuro.
extension BackdropToken {

    /// `linear-gradient(135deg, #b9c8ff 0%, #f1cfe4 48%, #ffe0bd 100%)`
    public static let vidroClaro = BackdropToken(
        base: TokenColor(red: 185 / 255, green: 200 / 255, blue: 255 / 255),
        stops: [
            Stop(color: TokenColor(red: 185 / 255, green: 200 / 255, blue: 255 / 255), location: 0),
            Stop(color: TokenColor(red: 241 / 255, green: 207 / 255, blue: 228 / 255), location: 0.48),
            Stop(color: TokenColor(red: 255 / 255, green: 224 / 255, blue: 189 / 255), location: 1),
        ],
        angle: 135
    )

    /// `#0b0b12` com dois halos: `#2b2f73` no canto superior esquerdo e
    /// `#5b2950` no inferior direito, ambos apagando a 70% do raio.
    public static let vidroNoite = BackdropToken(
        base: TokenColor(red: 11 / 255, green: 11 / 255, blue: 18 / 255),
        glows: [
            Glow(
                color: TokenColor(red: 43 / 255, green: 47 / 255, blue: 115 / 255),
                center: .topLeading, radius: 0.72
            ),
            Glow(
                color: TokenColor(red: 91 / 255, green: 41 / 255, blue: 80 / 255),
                center: .bottomTrailing, radius: 0.72
            ),
        ]
    )
}

extension PanelStyle {

    /// Folga canônica entre os painéis flutuantes, e deles para a borda da
    /// janela. O protótipo usa `padding: 10px; gap: 10px`.
    public static let vidroGap: CGFloat = 10
    public static let vidroRadius: CGFloat = 18

    public static let vidroClaro = PanelStyle(
        fill: TokenColor(red: 1, green: 1, blue: 1, opacity: 0.62),
        readerFill: TokenColor(red: 1, green: 1, blue: 1, opacity: 0.88),
        edge: TokenColor(red: 1, green: 1, blue: 1, opacity: 0.75),
        shadow: [
            ShadowToken(
                x: 0, y: 10, blur: 30,
                color: TokenColor(red: 40 / 255, green: 40 / 255, blue: 90 / 255, opacity: 0.08)
            )
        ],
        radius: vidroRadius, gap: vidroGap
    )

    public static let vidroNoite = PanelStyle(
        fill: TokenColor(red: 28 / 255, green: 28 / 255, blue: 40 / 255, opacity: 0.55),
        readerFill: TokenColor(red: 24 / 255, green: 24 / 255, blue: 34 / 255, opacity: 0.82),
        edge: TokenColor(red: 1, green: 1, blue: 1, opacity: 0.08),
        shadow: [
            ShadowToken(x: 0, y: 10, blur: 30, color: TokenColor(red: 0, green: 0, blue: 0, opacity: 0.35))
        ],
        radius: vidroRadius, gap: vidroGap
    )
}

extension Theme {
    /// Este tema flutua? É a única pergunta que o shell faz: com `panel` e
    /// `backdrop` ele desenha o gradiente e os painéis soltos; sem eles,
    /// desenha o que desenhava antes.
    public var isGlass: Bool { panel != nil && backdrop != nil }

    /// A cor **como ela é pintada**, e não como foi declarada.
    ///
    /// Os tokens do Vidro são translúcidos de propósito — é disso que o vidro é
    /// feito. Perguntar contraste a `rgba(255,255,255,0.62)` devolve a resposta
    /// do branco puro, que é mentira sobre o que o olho vê. Aqui a cor é
    /// composta sobre o fundo real da janela (a base do gradiente, ou `paper`
    /// nos temas sem gradiente) antes de qualquer conta de contraste.
    public func flattened(_ token: TokenColor) -> TokenColor {
        let under = backdrop?.base ?? paper
        guard token.opacity < 1 else { return token }
        let base = under.opacity < 1 ? paper : under
        return base.mixing(
            with: TokenColor(red: token.red, green: token.green, blue: token.blue),
            amount: token.opacity
        )
    }

    public func flattened(_ path: KeyPath<Theme, TokenColor>) -> TokenColor {
        flattened(self[keyPath: path])
    }

    /// O mesmo, mas sobre uma cor escolhida: um realce de linha é pintado
    /// **dentro** do painel, não sobre o gradiente nu, e é com o painel que o
    /// contraste dele precisa ser medido.
    public func flattened(
        _ path: KeyPath<Theme, TokenColor>, over background: TokenColor
    ) -> TokenColor {
        let token = self[keyPath: path]
        guard token.opacity < 1 else { return token }
        return background.mixing(
            with: TokenColor(red: token.red, green: token.green, blue: token.blue),
            amount: token.opacity
        )
    }

    /// O par claro/escuro deste tema.
    ///
    /// A regra é curta de propósito: o Vidro tem par de verdade (`vidro` ↔
    /// `vidro-noite`) e os outros 26 não têm — eles não foram desenhados em
    /// duplas. Para eles, o interruptor do trilho leva ao Vidro do lado
    /// oposto, que é o tema padrão do app: um tema claro vira `vidro-noite`,
    /// um escuro vira `vidro`. Ninguém fica preso sem destino, e nenhum par
    /// é inventado entre temas que não combinam.
    public var appearanceCounterpart: Theme {
        switch id {
        case "vidro": return .vidroNoite
        case "vidro-noite": return .vidro
        default: return isDark ? .vidro : .vidroNoite
        }
    }
}

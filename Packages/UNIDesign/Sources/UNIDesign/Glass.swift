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

    /// O painel **opaco** de um tema clássico: a mesma caixa flutuante do
    /// Vidro, feita só com os tokens do próprio tema.
    ///
    /// É o que o artboard `Painel-Classico` escreve para o Okami, token por
    /// token: o painel é `surface` (`#0B0B12`), o leitor é `surface2`
    /// (`#08080E`), a aresta é `line` (`#252636`) e a sombra é a do tema
    /// (`0 30px 90px` + o fio de 0,5pt). Nada de translúcido e nada de
    /// desfoque — é só a estrutura nova pintada com a paleta antiga.
    ///
    /// A folga é a mesma dos dois temas de vidro de propósito: ela é medida do
    /// desenho, não da paleta, e os semáforos nativos são postos no trilho a
    /// partir dela (`TrafficLightLayout.railLeading`). Um gap por tema moveria
    /// as bolinhas a cada troca de tema.
    public static func opaque(for theme: Theme) -> PanelStyle {
        PanelStyle(
            fill: theme.surface,
            readerFill: theme.surface2,
            edge: theme.line,
            shadow: theme.shadow,
            radius: theme.radiusLarge,
            gap: vidroGap
        )
    }
}

extension Theme {
    /// O shell novo — trilho à esquerda, coluna de contexto, painéis
    /// flutuantes, Painel/Caixa/Agenda redesenhados — é de **todos** os 28
    /// temas. A regra do dono: "os temas clássicos devem perder o vidro mas
    /// manter o design e todo restante".
    ///
    /// Fica como propriedade, e não como `true` espalhado pelo código, porque
    /// ela é o que cada chamada antiga de `isGlass` **queria dizer** quando
    /// falava de layout: assim um leitor vê de qual das duas perguntas aquela
    /// linha depende.
    public var usesFloatingPanels: Bool { true }

    /// Este tema é de **vidro**: painéis translúcidos sobre um gradiente, com
    /// desfoque atrás. Só `vidro` e `vidro-noite` são.
    ///
    /// Era isto que `isGlass` media, e era o layout que ele decidia por
    /// acidente — as duas perguntas moravam numa só. Aqui ela responde apenas
    /// pelo **material**: quem pergunta isto escolhe entre uma cor translúcida
    /// do protótipo e o token opaco do tema.
    public var isTranslucent: Bool { panel != nil && backdrop != nil }

    /// Como os painéis deste tema são desenhados. Todo tema tem um: o do
    /// Vidro vem declarado nos tokens, o dos 26 clássicos é montado a partir
    /// deles em `PanelStyle.opaque(for:)`.
    public var resolvedPanel: PanelStyle { panel ?? .opaque(for: self) }

    /// A folga entre painéis e deles para a borda da janela.
    public var panelGap: CGFloat { resolvedPanel.gap }

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

    // MARK: - As superfícies de dentro do painel
    //
    // O painel de vidro já é a caixa da tela. O que mora **dentro** dele tem
    // três alturas, e elas vêm literais dos protótipos `Painel-Vidro.dc.html`
    // e `Agenda-Vidro.dc.html`:
    //
    // - `glassCard`: o único cartão elevado do claro (`#ffffff`), o cartão
    //   levemente levantado do escuro (`#20202c`). É o "Comece por aqui".
    // - `glassTile`: o azulejo translúcido das três frentes.
    // - `glassRing`: o anel dos avatares sobrepostos, que é a cor do que está
    //   atrás deles.
    //
    // Fora do Vidro eles caem nos tokens de sempre, e nenhum dos 26 temas
    // antigos muda de aparência por existir isto aqui.

    /// `card` / `cardEdge` do protótipo: a única caixa elevada do painel.
    public var glassCard: TokenColor {
        guard isTranslucent else { return surface }
        return isDark
            ? TokenColor(red: 32 / 255, green: 32 / 255, blue: 44 / 255)
            : TokenColor(red: 1, green: 1, blue: 1)
    }

    public var glassCardEdge: TokenColor {
        guard isTranslucent else { return line }
        return isDark
            ? TokenColor(red: 1, green: 1, blue: 1, opacity: 0.08)
            : TokenColor(red: 1, green: 1, blue: 1, opacity: 0)
    }

    /// `tile` / `tileEdge`: o azulejo das frentes e dos cartões rasos.
    public var glassTile: TokenColor {
        guard isTranslucent else { return surface2 }
        return isDark
            ? TokenColor(red: 1, green: 1, blue: 1, opacity: 0.05)
            : TokenColor(red: 1, green: 1, blue: 1, opacity: 0.62)
    }

    public var glassTileEdge: TokenColor {
        guard isTranslucent else { return line2 }
        return isDark
            ? TokenColor(red: 1, green: 1, blue: 1, opacity: 0.06)
            : TokenColor(red: 1, green: 1, blue: 1, opacity: 0.80)
    }

    /// O fundo de uma janela solta — o compositor, por exemplo.
    ///
    /// No Vidro é o vidro do mock `Compositor.dc.html`:
    /// `rgba(255,255,255,0.96)` no claro e `rgba(26,26,36,0.94)` no escuro, por
    /// cima do gradiente. Translúcido o bastante para o gradiente aparecer nas
    /// bordas e fechado o bastante para texto longo ficar legível — é o mesmo
    /// critério do `readerFill` do painel.
    ///
    /// Nos 26 temas opacos é `surface`, que é o que a janela sempre pintou:
    /// mesma estrutura, sem vidro.
    public var glassWindow: TokenColor {
        guard isTranslucent else { return surface }
        return isDark
            ? TokenColor(red: 26 / 255, green: 26 / 255, blue: 36 / 255, opacity: 0.94)
            : TokenColor(red: 1, green: 1, blue: 1, opacity: 0.96)
    }

    /// A superfície de uma lista ou menu que **flutua** por cima do conteúdo.
    ///
    /// O defeito que isto conserta: a lista de sugestões de contato do
    /// compositor pintava o fundo com `surface`, e no Vidro `surface` é
    /// `rgba(28,28,40,0.55)` — translúcido de propósito, porque é a parede do
    /// painel. Por cima da linha do Assunto e da barra de formatação, essa
    /// parede deixa o texto de baixo atravessar os nomes: foi o print do dono
    /// do projeto, com "MAIS USADOS" ilegível sobre o assunto.
    ///
    /// Um menu não é parede: é um objeto elevado, e objeto elevado é **opaco**.
    /// Fora do Vidro os dois tokens caem em `surface`/`line`, que é o que os
    /// 26 temas antigos já pintavam ali.
    public var glassElevated: TokenColor { glassCard }

    public var glassElevatedEdge: TokenColor {
        guard isTranslucent else { return line }
        return isDark
            ? TokenColor(red: 1, green: 1, blue: 1, opacity: 0.12)
            : TokenColor(red: 20 / 255, green: 20 / 255, blue: 50 / 255, opacity: 0.12)
    }

    /// `ring`: o que está atrás dos avatares sobrepostos.
    public var glassRing: TokenColor {
        guard isTranslucent else { return paper }
        return isDark
            ? TokenColor(red: 35 / 255, green: 35 / 255, blue: 47 / 255)
            : TokenColor(red: 1, green: 1, blue: 1)
    }

    /// `soft` / `active` do protótipo: a calha do segmentado e o segmento
    /// escolhido, dentro do painel.
    public var glassSoft: TokenColor {
        guard isTranslucent else { return surface3 }
        return isDark
            ? TokenColor(red: 1, green: 1, blue: 1, opacity: 0.07)
            : TokenColor(red: 20 / 255, green: 20 / 255, blue: 50 / 255, opacity: 0.06)
    }

    public var glassActive: TokenColor {
        guard isTranslucent else { return surface }
        return isDark
            ? TokenColor(red: 1, green: 1, blue: 1, opacity: 0.14)
            : TokenColor(red: 1, green: 1, blue: 1)
    }

    /// O traço do "agora". O Vidro o quer laranja (`#f97316` do protótipo), e
    /// não no vermelho semântico que os outros temas usam: aqui o vermelho
    /// brigaria com o rosa do gradiente.
    public var nowLine: TokenColor {
        isTranslucent
            ? TokenColor(red: 249 / 255, green: 115 / 255, blue: 22 / 255)
            : live
    }

    /// A faixa do que já passou, dentro de uma trilha ou de uma coluna.
    public var glassPast: TokenColor {
        isDark
            ? TokenColor(red: 1, green: 1, blue: 1, opacity: 0.04)
            : TokenColor(red: 20 / 255, green: 20 / 255, blue: 50 / 255, opacity: 0.05)
    }

    /// A reunião em curso: azul cheio, com texto branco, como no protótipo.
    public var liveMeeting: TokenColor {
        TokenColor(red: 59 / 255, green: 130 / 255, blue: 246 / 255)
    }

    /// O par fundo/tinta de um compromisso pintado pela cor do calendário.
    ///
    /// No claro o fundo é a tinta a 18% e o texto é a **mesma** tinta
    /// escurecida — azul sobre azul-claro, verde sobre verde-claro. No escuro
    /// é a tinta a 25% com o texto clareado. É o que o protótipo escreve
    /// (`rgba(59,130,246,0.16)` com `#1e3a8a`; `0.26` com `#bfdbfe`), com uma
    /// vantagem: vale para qualquer cor que o calendário do sistema devolva, e
    /// não só para as três do desenho.
    public func glassEventFill(_ tint: TokenColor) -> TokenColor {
        TokenColor(
            red: tint.red, green: tint.green, blue: tint.blue,
            opacity: isDark ? 0.26 : 0.22
        )
    }

    public func glassEventInk(_ tint: TokenColor) -> TokenColor {
        isDark
            ? tint.mixing(with: TokenColor(red: 1, green: 1, blue: 1), amount: 0.62)
            : tint.mixing(with: TokenColor(red: 0, green: 0, blue: 0), amount: 0.55)
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

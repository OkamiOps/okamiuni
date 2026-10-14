import SwiftUI

/// A anatomia que **todo** modal, folha, popover e janela secundária do app
/// compartilha, copiada dos protótipos `ModalAgenda.dc.html`,
/// `ModalContas.dc.html`, `ModalJanelas.dc.html` e `ModalSistema.dc.html`.
///
/// Mora aqui, e não dentro de cada tela, porque o desenho é **um** e as telas
/// são doze: quando o raio da folha mudou de 18 para 20 no protótipo, o número
/// tinha de mudar num lugar só. Foi exatamente assim que dois `.stroke`
/// borrados sobreviveram um marco inteiro nesta base, cada um num arquivo que
/// ninguém lembrava ser o mesmo desenho.
///
/// ## Um layout para os 28 temas
///
/// `isGlass` decide **só o tratamento da superfície**: no Vidro a folha é o
/// branco (ou o quase-preto) elevado do protótipo com raio 20 e um halo no
/// botão primário; nos 26 temas opacos é `surface` com o raio e os tokens do
/// próprio tema, sem halo e sem desfoque. Estrutura, espaçamento, tamanhos e
/// posições são os mesmos nos dois casos — é o que o dono pediu quando disse
/// que os clássicos "mantêm o desenho e só perdem o vidro".
extension Theme {

    // MARK: - Medidas

    /// Larguras do protótipo, por tipo de superfície.
    public enum ModalWidth {
        /// Confirmação destrutiva: `width: 420px` (`ModalSistema`, confirmar).
        public static let confirm: CGFloat = 420
        /// Folha pequena: 460 (reconectar) a 500 (adicionar conta).
        public static let smallSheet: CGFloat = 460
        public static let accountSheet: CGFloat = 500
        /// Novo compromisso: `width: 620px`.
        public static let appointment: CGFloat = 620
        /// Popovers: 300 (mover para pasta) a 380 (atualização).
        public static let folderPopover: CGFloat = 300
        public static let themePopover: CGFloat = 360
        public static let updatePopover: CGFloat = 380
        /// Janelas próprias.
        public static let eventWindow: CGFloat = 640
        public static let messageWindow = CGSize(width: 880, height: 720)
    }

    /// `top: 56px` — a folha pende do **topo** da janela, centrada na
    /// horizontal, por cima do app visível e do véu.
    public static let modalSheetTop: CGFloat = 56

    /// Cabeçalho: `padding: 26px 28px 0`.
    public static let modalHeaderTop: CGFloat = 26
    public static let modalSide: CGFloat = 28
    /// Rodapé: `padding: 16px 28px 20px`, com a linha de um pixel em cima.
    public static let modalFooterTop: CGFloat = 16
    public static let modalFooterBottom: CGFloat = 20

    /// O título de um cabeçalho de folha, com o `letter-spacing: -0.02em` do
    /// protótipo. 23 na folha de conta, 20 na de reconectar, 24 no compromisso
    /// pronto — quem chama escolhe, o tracking vem de graça.
    public func modalTitleTracking(at size: CGFloat) -> CGFloat { -0.02 * size }

    // MARK: - Raios
    //
    // No Vidro são os literais do protótipo. Nos temas clássicos são os tokens
    // do próprio tema (no Okami, 2pt), que é o que "sem vidro, mesmo desenho"
    // quer dizer: a folha continua no mesmo lugar, com o canto do tema.

    public var modalSheetRadius: CGFloat { isGlass ? 20 : radiusLarge }
    public var modalPopoverRadius: CGFloat { isGlass ? 16 : radiusLarge }
    public var modalFieldRadius: CGFloat { isGlass ? 12 : radiusSmall }
    public var modalButtonRadius: CGFloat { isGlass ? 10 : radiusSmall }

    // MARK: - Superfícies

    /// O corpo da folha, da janela própria e do balão: **opaco**.
    ///
    /// Um modal é objeto elevado, e objeto elevado não deixa o de baixo
    /// atravessar — é a mesma regra que `glassElevated` já cumpre para o menu
    /// do compositor. Protótipo: `#ffffff` no claro, `#1d1d28` no escuro,
    /// `#0B0B12` no clássico (que é o `surface` do Okami, literalmente).
    public var modalSheet: TokenColor { glassElevated }

    /// A aresta da folha. No Vidro é o fio de luz; nos clássicos é a borda de
    /// controle do tema (`#323348` no Okami, o `sheetEdge` do protótipo).
    public var modalSheetEdge: TokenColor { isGlass ? glassElevatedEdge : btnLine }

    /// O véu por trás de um modal centrado ou de uma folha.
    ///
    /// `rgba(30,25,70,0.22)` no claro, `rgba(5,5,10,0.45)` no escuro,
    /// `rgba(6,6,9,0.55)` no clássico escuro: o véu é mais fechado quando não
    /// há desfoque para separar as camadas.
    public var modalScrim: TokenColor {
        let opacity: Double = isGlass ? (isDark ? 0.45 : 0.22) : (isDark ? 0.55 : 0.30)
        return TokenColor(
            red: isDark ? 5 / 255 : 30 / 255,
            green: isDark ? 5 / 255 : 25 / 255,
            blue: isDark ? 10 / 255 : 70 / 255,
            opacity: opacity
        )
    }

    /// O campo de um formulário dentro da folha: `#f6f6fa` /
    /// `rgba(255,255,255,0.06)` / `#14141E`.
    public var modalField: TokenColor {
        guard isGlass else { return btn }
        return isDark
            ? TokenColor(red: 1, green: 1, blue: 1, opacity: 0.06)
            : TokenColor(red: 246 / 255, green: 246 / 255, blue: 250 / 255)
    }

    public var modalFieldEdge: TokenColor {
        guard isGlass else { return btnLine }
        return isDark
            ? TokenColor(red: 1, green: 1, blue: 1, opacity: 0.14)
            : TokenColor(red: 20 / 255, green: 20 / 255, blue: 50 / 255, opacity: 0.12)
    }

    /// A calha rasa de dentro da folha — a trilha do dia, o bloco do teste
    /// IMAP, o recado da reconexão. `rgba(20,20,50,0.05)` / `0.05` branco /
    /// `#14141E`.
    public var modalSoft: TokenColor {
        guard isGlass else { return surface3 }
        return isDark
            ? TokenColor(red: 1, green: 1, blue: 1, opacity: 0.05)
            : TokenColor(red: 20 / 255, green: 20 / 255, blue: 50 / 255, opacity: 0.05)
    }

    /// A linha de um pixel de dentro da folha: `rgba(20,20,50,0.08)`.
    public var modalLine: TokenColor { line }

    /// O botão secundário do protótipo (`btn2` / `btn2Line`): "Agora não",
    /// "Ao fechar o app", "Cancelar" de uma confirmação.
    public var modalButton: TokenColor { isGlass ? (isDark ? TokenColor(red: 1, green: 1, blue: 1, opacity: 0.08) : TokenColor(red: 1, green: 1, blue: 1)) : btn }

    public var modalButtonEdge: TokenColor { isGlass ? modalFieldEdge : btnLine }

    // MARK: - O halo do primário

    /// `box-shadow: 0 6px 16px rgba(79,70,229,0.30)` — e **nada** fora do
    /// Vidro: o protótipo escreve `accentGlow: 'none'` no clássico, porque um
    /// halo colorido num tema opaco lê como borrão, não como elevação.
    public var modalAccentGlow: [ShadowToken] {
        guard isGlass else { return [] }
        return [
            ShadowToken(
                x: 0, y: 6, blur: 16,
                color: TokenColor(
                    red: accent.red, green: accent.green, blue: accent.blue, opacity: 0.30
                )
            )
        ]
    }

    /// A sombra de uma folha ou janela solta:
    /// `0 30px 80px rgba(40,30,110,0.28), 0 2px 8px rgba(30,30,80,0.10)`.
    /// Fora do Vidro é a sombra do próprio tema — no Okami, a que já tem o fio
    /// de 0,5 em volta.
    public var modalShadow: [ShadowToken] {
        guard isGlass else { return shadow }
        return isDark
            ? [
                ShadowToken(x: 0, y: 30, blur: 80, color: TokenColor(red: 0, green: 0, blue: 0, opacity: 0.55)),
                ShadowToken(x: 0, y: 2, blur: 8, color: TokenColor(red: 0, green: 0, blue: 0, opacity: 0.40)),
            ]
            : [
                ShadowToken(
                    x: 0, y: 30, blur: 80,
                    color: TokenColor(red: 40 / 255, green: 30 / 255, blue: 110 / 255, opacity: 0.28)
                ),
                ShadowToken(
                    x: 0, y: 2, blur: 8,
                    color: TokenColor(red: 30 / 255, green: 30 / 255, blue: 80 / 255, opacity: 0.10)
                ),
            ]
    }

    // MARK: - Cores de recado dos modais

    /// O verde do "15h está livre" e do passo cumprido do teste IMAP:
    /// `#047857` no claro, `#34d399` no escuro.
    public var modalGreen: TokenColor { success }

    /// O vermelho do destrutivo: a tinta do ícone e o fundo do botão.
    /// `#dc2626` / `#e11d48` no protótipo; aqui é o `remove` do tema, que é a
    /// mesma função semântica e já vira com os 28.
    public var modalRed: TokenColor { remove }

    public var modalRedSoft: TokenColor {
        isGlass
            ? TokenColor(
                red: remove.red, green: remove.green, blue: remove.blue,
                opacity: isDark ? 0.14 : 0.10
            )
            : surface3
    }
}

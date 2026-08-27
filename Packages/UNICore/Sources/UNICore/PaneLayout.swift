import CoreGraphics

/// Quais painéis cabem numa janela desta largura, dada a intenção do usuário.
///
/// A decisão é aritmética pura e mora aqui, fora de qualquer `View`: um `View`
/// do SwiftUI é implicitamente `@MainActor` no Swift 6, e um `static` dentro
/// dele herda esse isolamento e trapa em runtime quando um teste nonisolated o
/// chama. Foi o que já aconteceu com `AgendaRail`, resolvido do mesmo jeito
/// (`AgendaSummary`).
///
/// ## Intenção e resultado são coisas diferentes
///
/// `wantsSidebar` e `wantsAgenda` são o que o usuário pediu pelos botões da
/// barra. O que esta função devolve é o que **cabe**. A janela pode negar os
/// dois; como nada aqui é persistido entre chamadas, quando ela cresce de novo
/// a intenção volta a valer sozinha. É isso que impede o defeito clássico —
/// abrir a lateral, encolher a janela, alargar de novo e a lateral não voltar.
public struct PaneLayout: Sendable, Hashable {
    public let sidebarExpanded: Bool
    public let agendaVisible: Bool
    public let messageListWidth: CGFloat

    // MARK: - As larguras canônicas
    //
    // Estes são os valores de origem. As `View`s os consomem daqui em vez de
    // cravar `.frame(width:)` com a mesma literal repetida em quatro arquivos.

    /// Barra lateral aberta. Protótipo: 236px.
    public static let expandedSidebarWidth: CGFloat = 236

    /// Barra lateral recolhida — a trilha da Task 7B. A lateral nunca some por
    /// completo; recolhida ela é isto.
    public static let railWidth: CGFloat = 62

    /// Trilha da agenda. Protótipo: 262px.
    public static let agendaWidth: CGFloat = 262

    /// O leitor nunca fica abaixo disto. Abaixo de ~420pt o corpo serif 16
    /// deixa de caber numa medida legível e o cartão de resumo quebra.
    public static let readerMinimumWidth: CGFloat = 420

    /// A medida que o leitor tem no ponto de fidelidade da Task P (1440 com
    /// tudo visível: 1440 − 236 − 370 − 262). É o ponto de equilíbrio: até o
    /// leitor alcançar isto, a lista cede; a partir daí, a lista volta a
    /// crescer com a janela até o teto da sua faixa.
    ///
    /// É esta constante que faz `resolve(width: 1440, …)` devolver exatamente
    /// os 370 da lista que a Task P alinhou. Mexer nela desloca a tela inteira
    /// em 1440 e quebra o marco anterior.
    public static let readerComfortableWidth: CGFloat = 572

    // MARK: - As fronteiras

    /// Abaixo disto a lateral recolhe para a trilha.
    public static let sidebarBreakpoint: CGFloat = 1120

    /// Abaixo disto a agenda sai. É o primeiro painel a sair porque é o único
    /// cujo conteúdo o leitor não precisa para ser útil.
    public static let agendaBreakpoint: CGFloat = 1360

    /// Faixa da lista quando a lateral está aberta.
    static let wideListRange: ClosedRange<CGFloat> = 340...420

    /// Faixa da lista quando a lateral está recolhida — janela apertada, a
    /// lista pode ceder mais 20pt de cada lado.
    static let narrowListRange: ClosedRange<CGFloat> = 320...380

    /// Largura que a lateral efetivamente ocupa neste layout.
    public var sidebarWidth: CGFloat {
        sidebarExpanded ? Self.expandedSidebarWidth : Self.railWidth
    }

    /// `wantsSidebar` e `wantsAgenda` são a intenção do usuário, não o resultado.
    /// A janela pode negar as duas; quando ela cresce, a intenção volta a valer.
    public static func resolve(
        width: CGFloat,
        wantsSidebar: Bool,
        wantsAgenda: Bool
    ) -> PaneLayout {
        // As fronteiras olham a largura da janela, não a intenção: quem
        // recolheu a lateral de propósito numa janela larga não muda a faixa em
        // que a lista vive, só devolve os 174pt de diferença ao resto.
        let sidebarExpanded = wantsSidebar && width >= sidebarBreakpoint
        let agendaVisible = wantsAgenda && width >= agendaBreakpoint

        let listRange = width >= sidebarBreakpoint ? wideListRange : narrowListRange

        // O que sobra para lista + leitor, depois dos dois painéis de largura
        // canônica.
        let available = width
            - (sidebarExpanded ? expandedSidebarWidth : railWidth)
            - (agendaVisible ? agendaWidth : 0)

        // A lista fica com o que exceder a medida confortável do leitor, presa
        // dentro da faixa. Numa janela apertada isso a joga no piso da faixa e
        // é o leitor que encolhe; numa janela larga ela sobe até o teto e todo
        // o resto do crescimento vai para o leitor.
        let listWidth = min(
            listRange.upperBound,
            max(listRange.lowerBound, (available - readerComfortableWidth).rounded())
        )

        return PaneLayout(
            sidebarExpanded: sidebarExpanded,
            agendaVisible: agendaVisible,
            messageListWidth: listWidth
        )
    }
}

import CoreGraphics
import Foundation
import Observation

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

    /// Largura que a trilha de agenda recebe neste layout. É `0` quando a
    /// agenda não aparece; caso contrário, a canônica de 262 ou o que o usuário
    /// arrastou, depois de passar pelas mesmas travas da lista.
    public let agendaRailWidth: CGFloat

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

    // MARK: - As faixas do arraste
    //
    // As duas faixas acima foram escolhidas para o **recolhimento automático**:
    // são a margem de manobra que a janela tem para acomodar a lista sozinha,
    // e é dela que sai o ponto de fidelidade de 370 em 1440. Elas continuam
    // valendo intactas enquanto o usuário não arrastar nada.
    //
    // O gesto é outra pergunta. Quem agarra a divisória está dizendo qual
    // largura quer, não pedindo à janela que escolha, e travá-lo nos mesmos
    // 100pt de manobra faria a divisória parar de andar quase assim que começa.
    // Por isso o arraste tem faixas próprias, mais largas. O que **não** muda é
    // o piso do leitor: `readerMinimumWidth` vale para os dois caminhos, e é
    // ele que recorta qualquer preferência que não caiba.

    /// Faixa em que uma largura de lista **arrastada** pode viver.
    ///
    /// Piso 260: abaixo disso a fila de chips da linha (host + etiquetas) não
    /// cabe mais numa linha só e o assunto vira uma palavra truncada. Teto 640:
    /// o suficiente para a lista virar o painel dominante numa tela grande sem
    /// nunca conseguir, sozinha, espremer o leitor numa janela de 1440.
    public static let draggableListRange: ClosedRange<CGFloat> = 260...640

    /// Faixa em que uma largura de agenda **arrastada** pode viver.
    ///
    /// Piso 200: a trilha gasta 66pt fixos com a calha das horas (30), a folga
    /// (6), o recuo dos cartões (2) e os 14 de calha de cada lado; abaixo de
    /// 200 sobram menos de 134pt para o título do compromisso. Teto 400: a
    /// trilha é um resumo do dia, não uma segunda tela.
    public static let draggableAgendaRange: ClosedRange<CGFloat> = 200...400

    /// Prende uma largura de lista arrastada na faixa do gesto. Isto é o que
    /// impede uma preferência gravada de crescer sem limite.
    public static func clampDraggedListWidth(_ width: CGFloat) -> CGFloat {
        clamp(width, into: draggableListRange)
    }

    /// Idem para a agenda.
    public static func clampDraggedAgendaWidth(_ width: CGFloat) -> CGFloat {
        clamp(width, into: draggableAgendaRange)
    }

    private static func clamp(_ value: CGFloat, into range: ClosedRange<CGFloat>) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, value.rounded()))
    }

    /// Largura que a lateral efetivamente ocupa neste layout.
    public var sidebarWidth: CGFloat {
        sidebarExpanded ? Self.expandedSidebarWidth : Self.railWidth
    }

    /// A lateral aberta ou recolhida, só isso — intenção cruzada com a largura
    /// da janela, sem negociar lista nem leitor.
    ///
    /// Existe porque a aba Agenda usa a **mesma** lateral do email (no
    /// protótipo ela é do shell, fora do `sc-if` que separa as duas telas) mas
    /// não tem lista de mensagens nem leitor para repartir. Chamar `resolve` lá
    /// obrigaria a inventar painéis que aquela tela não tem só para ler um
    /// booleano. `resolve` chama esta função, então a fronteira é uma só: mexer
    /// em `sidebarBreakpoint` move as duas abas juntas.
    public static func sidebarExpanded(width: CGFloat, wantsSidebar: Bool) -> Bool {
        wantsSidebar && width >= sidebarBreakpoint
    }

    /// Largura da lateral para a aba que não reparte mais nada com ela.
    public static func sidebarWidth(width: CGFloat, wantsSidebar: Bool) -> CGFloat {
        sidebarExpanded(width: width, wantsSidebar: wantsSidebar)
            ? expandedSidebarWidth : railWidth
    }

    // MARK: - Onde ficam as divisórias
    //
    // A `View` precisa saber em que x pousar cada alvo de arraste. É a mesma
    // aritmética que distribui os painéis, então mora aqui e não numa `View`
    // `@MainActor` — pelo mesmo motivo que `resolve` mora aqui.

    /// x da linha entre a lista e o leitor, medido da borda esquerda da janela.
    public var messageListTrailingEdge: CGFloat {
        sidebarWidth + messageListWidth
    }

    /// x da linha entre o leitor e a trilha de agenda. Só faz sentido quando a
    /// agenda aparece; com ela escondida, é a própria borda direita da janela.
    public func agendaLeadingEdge(inWindowOfWidth width: CGFloat) -> CGFloat {
        width - agendaRailWidth
    }

    /// O que sobra para o leitor. Nunca abaixo de `readerMinimumWidth` — é a
    /// invariante que `resolve` protege contra qualquer preferência gravada.
    public func readerWidth(inWindowOfWidth width: CGFloat) -> CGFloat {
        width - sidebarWidth - messageListWidth - agendaRailWidth
    }

    /// `wantsSidebar` e `wantsAgenda` são a intenção do usuário, não o resultado.
    /// A janela pode negar as duas; quando ela cresce, a intenção volta a valer.
    ///
    /// `draggedListWidth` e `draggedAgendaWidth` são a **terceira e a quarta**
    /// intenções, e obedecem exatamente à mesma regra: são o que o usuário
    /// pediu arrastando a divisória, não o que ele vai receber. `nil` significa
    /// "nunca arrastei esta divisória" — e é diferente de um número, porque com
    /// `nil` a lista continua sendo negociada pela janela como sempre foi.
    ///
    /// O arraste **não** é um atalho para fora deste cálculo: uma preferência
    /// que não caiba é recortada aqui, do mesmo jeito que uma lateral aberta
    /// numa janela de 900pt é negada aqui. Guardá-la intacta enquanto a janela
    /// a nega é o que faz a largura arrastada voltar sozinha quando a janela
    /// cresce de novo — a mesma propriedade que a Task R deu aos dois botões.
    public static func resolve(
        width: CGFloat,
        wantsSidebar: Bool,
        wantsAgenda: Bool,
        draggedListWidth: CGFloat? = nil,
        draggedAgendaWidth: CGFloat? = nil
    ) -> PaneLayout {
        // As fronteiras olham a largura da janela, não a intenção: quem
        // recolheu a lateral de propósito numa janela larga não muda a faixa em
        // que a lista vive, só devolve os 174pt de diferença ao resto.
        let sidebarExpanded = self.sidebarExpanded(width: width, wantsSidebar: wantsSidebar)
        let agendaVisible = wantsAgenda && width >= agendaBreakpoint

        let sidebar = sidebarExpanded ? expandedSidebarWidth : railWidth

        // A agenda arrastada vive na sua própria faixa; sem arraste, é a
        // canônica de 262 de sempre.
        var agenda: CGFloat = 0
        if agendaVisible {
            agenda = draggedAgendaWidth.map(clampDraggedAgendaWidth) ?? agendaWidth
        }

        // O piso da lista depende de qual dos dois caminhos a trouxe até aqui:
        // sem arraste é o piso da faixa automática, com arraste é o do gesto.
        // É esse piso que a trava do leitor pode consumir, e não mais que isso.
        let listFloor: CGFloat
        let list: CGFloat
        if let dragged = draggedListWidth {
            listFloor = draggableListRange.lowerBound
            list = clampDraggedListWidth(dragged)
        } else {
            let listRange = width >= sidebarBreakpoint ? wideListRange : narrowListRange
            listFloor = listRange.lowerBound

            // O que sobra para lista + leitor, depois dos dois painéis de
            // largura canônica.
            let available = width - sidebar - agenda

            // A lista fica com o que exceder a medida confortável do leitor,
            // presa dentro da faixa. Numa janela apertada isso a joga no piso
            // da faixa e é o leitor que encolhe; numa janela larga ela sobe até
            // o teto e todo o resto do crescimento vai para o leitor.
            list = min(
                listRange.upperBound,
                max(listRange.lowerBound, (available - readerComfortableWidth).rounded())
            )
        }

        let (listWidth, agendaRailWidth) = fitReader(
            windowWidth: width,
            sidebar: sidebar,
            list: list,
            listFloor: listFloor,
            agenda: agenda,
            agendaVisible: agendaVisible
        )

        return PaneLayout(
            sidebarExpanded: sidebarExpanded,
            agendaVisible: agendaVisible,
            messageListWidth: listWidth,
            agendaRailWidth: agendaRailWidth
        )
    }

    /// A trava que nenhuma preferência atravessa: o leitor fica com pelo menos
    /// `readerMinimumWidth`.
    ///
    /// Quem cede primeiro é a lista, porque no modelo da Task R ela já é o
    /// painel elástico — a agenda é uma trilha de largura de propósito fixo. Se
    /// a lista chegar ao seu piso e ainda faltar, a agenda cede o resto.
    ///
    /// No caminho automático isto é um no-op: aquela fórmula já nasce
    /// respeitando o piso do leitor, e é o teste de varredura da Task R que
    /// prova. Aqui ela vale para as preferências arrastadas.
    private static func fitReader(
        windowWidth: CGFloat,
        sidebar: CGFloat,
        list: CGFloat,
        listFloor: CGFloat,
        agenda: CGFloat,
        agendaVisible: Bool
    ) -> (list: CGFloat, agenda: CGFloat) {
        let deficit = readerMinimumWidth - (windowWidth - sidebar - list - agenda)
        guard deficit > 0 else { return (list, agenda) }

        let fromList = min(deficit, max(0, list - listFloor))
        let remaining = deficit - fromList

        guard remaining > 0, agendaVisible else {
            return (list - fromList, agenda)
        }

        let agendaFloor = draggableAgendaRange.lowerBound
        let fromAgenda = min(remaining, max(0, agenda - agendaFloor))
        return (list - fromList, agenda - fromAgenda)
    }
}

/// A largura que o usuário arrastou para cada divisória, guardada entre
/// execuções.
///
/// Uma preferência por painel, não uma largura global: a lista e a trilha de
/// agenda são decisões independentes, e quem estreita a lista não está pedindo
/// nada sobre a agenda.
///
/// O que fica gravado é a **intenção**, não o que coube. Uma lista de 640
/// arrastada numa tela de 27" continua valendo 640 depois de a janela encolher
/// para 900 e a `PaneLayout` recortá-la para caber; ao voltar para a tela
/// grande, ela volta para 640 sozinha. Gravar o valor recortado seria apagar a
/// preferência por estreitamento — exatamente o defeito que a Task R eliminou
/// nos dois botões da barra.
///
/// `nil` é um estado de verdade e não pode virar zero: significa "esta
/// divisória nunca foi arrastada", e é ele que devolve a lista à negociação
/// automática da janela. É o que o duplo clique restaura.
@MainActor
@Observable
public final class PaneWidthStore {
    private static let listKey = "okamiuni.paneWidth.messageList"
    private static let agendaKey = "okamiuni.paneWidth.agenda"

    /// `nil` = nunca arrastada; a janela decide, como antes do gesto existir.
    public private(set) var messageList: CGFloat?
    public private(set) var agenda: CGFloat?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` e não `double(forKey:)`: aquele devolve 0 para
        // chave ausente, e 0 aqui é uma largura, não um "não gravado".
        self.messageList = (defaults.object(forKey: Self.listKey) as? Double).map { CGFloat($0) }
        self.agenda = (defaults.object(forKey: Self.agendaKey) as? Double).map { CGFloat($0) }
    }

    private let defaults: UserDefaults

    /// Grava a largura de lista que o gesto produziu, já presa na faixa do
    /// arraste.
    public func setMessageList(_ width: CGFloat) {
        let clamped = PaneLayout.clampDraggedListWidth(width)
        messageList = clamped
        defaults.set(Double(clamped), forKey: Self.listKey)
    }

    public func setAgenda(_ width: CGFloat) {
        let clamped = PaneLayout.clampDraggedAgendaWidth(width)
        agenda = clamped
        defaults.set(Double(clamped), forKey: Self.agendaKey)
    }

    /// Duplo clique na divisória: devolve o painel à largura canônica, que é
    /// dizer devolvê-lo à decisão da janela.
    public func resetMessageList() {
        messageList = nil
        defaults.removeObject(forKey: Self.listKey)
    }

    public func resetAgenda() {
        agenda = nil
        defaults.removeObject(forKey: Self.agendaKey)
    }
}

import SwiftUI
import UNICore
import UNIDesign

/// **A Mesa.** O corpo do assistente entre o cabeçalho e o campo —
/// `design/Mesa2.dc.html`, estados `vazio`, `nota` e `trabalhando`, com os
/// objetos `rascunho` e `evento` de `design/Leitor-IA.dc.html`.
///
/// ## O que a Mesa troca
///
/// A Presença desenhava um dossiê: manchete, recibo e itens numerados. A Mesa
/// desenha **objetos sobre uma superfície**: a pergunta é uma lasca de acento
/// à direita, e cada coisa que o assistente produz é uma caixa com versalete,
/// corpo e as ações que valem para ela. A sessão, os provedores, as
/// ferramentas e o histórico são os mesmos — isto é apresentação.
///
/// ## A mesa já posta
///
/// Ao abrir sem conversa nenhuma, a mesa **já tem o dia em cima dela**: o
/// e-mail que espera há mais tempo, o próximo compromisso e uma promessa em
/// aberto, do mesmo `DayPlan` que alimenta o Painel. Sem nenhum deles a mesa
/// não finge: a segunda linha deixa de dizer que separou alguma coisa e as
/// sugestões sobem para logo abaixo da saudação, em vez de deixarem um vão.
///
/// ## Onde ela difere do desenho, e por quê
///
/// O desenho espalha os objetos em posições absolutas, com rotações de um
/// grau. Isso só fecha para a quantidade exata de objetos do artboard: uma
/// conversa de verdade tem de rolar, e dois objetos sobrepostos esconderiam
/// texto. Aqui os objetos empilham na vertical, com a largura máxima do maior
/// objeto do desenho (`MesaMetrics.objectMaxWidth`, 560) e centrados — todas
/// as medidas de dentro do objeto são as do desenho.
///
/// A pergunta mais recente mora **acima** da mesa, como no desenho. Turnos
/// anteriores rolam dentro dela, em ordem.
struct AssistantMesa: View {

    @Environment(\.theme) private var theme

    let conversation: AssistantConversation
    let session: AssistantSession
    /// O primeiro nome de quem usa o app, para a saudação do vazio. `nil`
    /// deixa a saudação sem nome — inventar um seria a tela mentindo.
    var ownerName: String?
    /// O nome do herói do dia, para a primeira pergunta sugerida.
    var heroName: String?
    /// A gaveta é estreita: os recuos laterais caem para os da gaveta do
    /// desenho (`padding: 2px 18px 0`), e o campo aperta.
    var compact = false
    let onRun: (AssistantProposalCard) -> Void
    let onReveal: (String) -> Void

    private var gutter: CGFloat {
        compact ? MesaMetrics.drawerHeaderPadding.leading : MesaMetrics.greetingPadding.leading
    }

    /// A mesa está vazia de conversa — é a hora de mostrar o dia.
    private var isEmpty: Bool {
        conversation.messages.isEmpty && !conversation.isLoading
    }

    private var dayItems: [MesaDayItem] { session.dayItems }

    private var suggestions: [String] {
        AssistantDrawerCopy.chips(heroName: heroName)
    }

    private var objects: [MesaObject] {
        MesaObject.table(
            for: conversation.messages, lastReceipt: session.lastReceipt
        )
    }

    /// A pergunta mais recente — a que o desenho põe acima da mesa.
    private var lastAsked: MesaObject? {
        objects.last { if case .asked = $0 { true } else { false } }
    }

    private var onTable: [MesaObject] {
        guard let lastAsked else { return objects }
        return objects.filter { $0.id != lastAsked.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEmpty {
                greeting
            } else if let lastAsked {
                MesaObjectView(
                    object: lastAsked, session: session,
                    onRun: onRun, onReveal: onReveal
                )
                .padding(.horizontal, gutter)
                .padding(.top, MesaMetrics.askedPadding.top)
            }

            if conversation.isLoading, !session.steps.isEmpty {
                MesaSteps(steps: session.steps)
                    .padding(.horizontal, gutter)
                    .padding(.top, MesaMetrics.stepsPadding.top)
            }

            mesa
        }
    }

    // MARK: O vazio

    /// "Boa tarde, Marcos." e a segunda linha.
    ///
    /// A segunda linha **só diz que separou alguma coisa quando há alguma
    /// coisa**: com a mesa limpa ela vira o convite, porque "separei o que não
    /// pode esperar" sobre o nada é a tela mentindo sobre o trabalho — a mesma
    /// regra do recibo de passos.
    private var greeting: some View {
        VStack(alignment: .leading, spacing: MesaMetrics.greetingGap) {
            Text(DashboardFocus.greeting(
                nowMinute: AgendaClock.minutesSinceMidnight(), name: ownerName
            ))
            .font(theme.sans.font(size: MesaMetrics.greetingSize, weight: .bold))
            .tracking(MesaMetrics.greetingSize * MesaMetrics.greetingTracking)
            .foregroundStyle(theme.ink.color)
            Text(dayItems.isEmpty ? MesaCopy.emptyInvitation : MesaCopy.separated)
                .font(theme.sans.font(size: MesaMetrics.greetingSubSize))
                .foregroundStyle(theme.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, gutter)
        .padding(.top, MesaMetrics.greetingPadding.top)
        .accessibilityElement(children: .combine)
    }

    // MARK: A mesa

    /// A superfície pontilhada com os objetos em cima dela.
    ///
    /// As sugestões moram **dentro** dela, e não embaixo: pendurá-las no pé
    /// deixava um vão enorme entre a saudação e elas sempre que não havia o
    /// que mostrar.
    private var mesa: some View {
        ScrollView {
            VStack(alignment: .center, spacing: MesaMetrics.objectGap) {
                if isEmpty {
                    ForEach(dayItems) { item in
                        MesaDayItemView(
                            item: item,
                            onAsk: { conversation.ask($0) },
                            onReveal: onReveal
                        )
                        .frame(maxWidth: MesaMetrics.objectMaxWidth)
                    }
                } else {
                    ForEach(onTable) { objeto in
                        MesaObjectView(
                            object: objeto, session: session,
                            onRun: onRun, onReveal: onReveal
                        )
                        .frame(maxWidth: MesaMetrics.objectMaxWidth)
                    }
                }
                if conversation.isLoading {
                    MesaBirthingObject(caps: MesaCopy.draftWriting)
                        .frame(maxWidth: MesaMetrics.objectMaxWidth)
                    MesaOutlineButton(
                        title: MesaCopy.stopHere, padding: MesaMetrics.stopPadding
                    ) {
                        conversation.cancel()
                    }
                    .padding(.top, 8)
                }
                if let falha = conversation.failure {
                    AssistantFailureBand(
                        failure: falha, onRetry: conversation.retry, onOpenSettings: {}
                    )
                    .frame(maxWidth: MesaMetrics.objectMaxWidth)
                }
                if !conversation.isLoading {
                    // As mesmas linhas com seta nos dois lugares, alinhadas
                    // pela borda esquerda dos objetos.
                    MesaSuggestionRows(
                        suggestions: suggestions,
                        isDisabled: conversation.isLoading,
                        onAsk: { conversation.ask($0) }
                    )
                    .frame(maxWidth: MesaMetrics.objectMaxWidth, alignment: .leading)
                    .padding(.top, isEmpty && dayItems.isEmpty ? 0 : 6)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(compact ? MesaMetrics.objectGap : MesaMetrics.mesaInset)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        // **Sem fundo do sistema.** Uma `ScrollView` do AppKit pinta a própria
        // parede, e ela cobria o pontilhado numa faixa no alto da mesa.
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MesaDots())
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .padding(.horizontal, MesaMetrics.mesaMargin.leading)
        .padding(.top, MesaMetrics.mesaMargin.top)
        .accessibilityIdentifier("assistant-mesa")
    }
}

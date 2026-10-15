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
            if conversation.messages.isEmpty, !conversation.isLoading {
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

            if conversation.messages.isEmpty, !conversation.isLoading {
                suggestions
            }
        }
    }

    // MARK: O vazio

    /// "Boa tarde, Marcos." e o convite. A segunda linha **não** é a do
    /// desenho: ver `MesaCopy.emptyInvitation`.
    private var greeting: some View {
        VStack(alignment: .leading, spacing: MesaMetrics.greetingGap) {
            Text(DashboardFocus.greeting(
                nowMinute: AgendaClock.minutesSinceMidnight(), name: ownerName
            ))
            .font(theme.sans.font(size: MesaMetrics.greetingSize, weight: .bold))
            .tracking(MesaMetrics.greetingSize * MesaMetrics.greetingTracking)
            .foregroundStyle(theme.ink.color)
            Text(MesaCopy.emptyInvitation)
                .font(theme.sans.font(size: MesaMetrics.greetingSubSize))
                .foregroundStyle(theme.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, gutter)
        .padding(.top, MesaMetrics.greetingPadding.top)
        .accessibilityElement(children: .combine)
    }

    /// As perguntas de partida, em linha com a seta do desenho.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(AssistantDrawerCopy.chips(heroName: heroName), id: \.self) { texto in
                Button { conversation.ask(texto) } label: {
                    HStack(spacing: MesaMetrics.suggestionGap) {
                        Image(systemName: "arrow.right")
                            .font(.system(
                                size: MesaMetrics.suggestionGlyph, weight: .semibold
                            ))
                            .foregroundStyle(theme.accentInk.color)
                        Text(texto)
                            .font(theme.sans.font(size: MesaMetrics.suggestionSize))
                            .foregroundStyle(theme.ink2.color)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(MesaMetrics.suggestionRowPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .disabled(conversation.isLoading)
            }
        }
        .padding(.horizontal, gutter - MesaMetrics.suggestionRowPadding.leading)
        .padding(.top, MesaMetrics.suggestionPadding.top)
        .padding(.bottom, MesaMetrics.suggestionPadding.bottom)
    }

    // MARK: A mesa

    /// A superfície pontilhada com os objetos em cima dela.
    private var mesa: some View {
        ScrollView {
            VStack(alignment: .center, spacing: MesaMetrics.objectGap) {
                ForEach(onTable) { objeto in
                    MesaObjectView(
                        object: objeto, session: session,
                        onRun: onRun, onReveal: onReveal
                    )
                    .frame(maxWidth: MesaMetrics.objectMaxWidth)
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
                if !conversation.isLoading, !conversation.messages.isEmpty {
                    followUps
                }
            }
            .frame(maxWidth: .infinity)
            .padding(compact ? MesaMetrics.objectGap : MesaMetrics.mesaInset)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MesaDots())
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .padding(.horizontal, MesaMetrics.mesaMargin.leading)
        .padding(.top, MesaMetrics.mesaMargin.top)
        .accessibilityIdentifier("assistant-mesa")
    }

    /// As perguntas seguintes, no pé da mesa: pastilha de campo com moldura,
    /// como no desenho (`field` / `fieldLine`, `padding: 8px 13px`).
    private var followUps: some View {
        FlowLayout(spacing: MesaMetrics.followUpGap, rowSpacing: MesaMetrics.followUpGap) {
            ForEach(AssistantDrawerCopy.chips(heroName: heroName), id: \.self) { texto in
                Button { conversation.ask(texto) } label: {
                    Text(texto)
                        .font(theme.sans.font(
                            size: MesaMetrics.followUpSize, weight: .medium
                        ))
                        .foregroundStyle(theme.ink2.color)
                        .lineLimit(1)
                        .padding(MesaMetrics.followUpPadding)
                        .background(theme.surface2.color)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                        .overlay {
                            RoundedRectangle(cornerRadius: theme.radiusSmall)
                                .strokeBorder(theme.btnLine.color, lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
                .disabled(conversation.isLoading)
            }
        }
        .frame(maxWidth: MesaMetrics.objectMaxWidth)
        .padding(.top, 8)
    }
}

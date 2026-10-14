import SwiftUI
import UNICore
import UNIDesign

/// A janela destacada do assistente — `design/IA-Presenca.dc.html`, a janela
/// de 880 × 744 dos artboards `resposta` e `trabalhando`.
///
/// **É a mesma conversa da gaveta**, e não uma segunda. Quem a segura é a
/// `AssistantSession`, que vive acima das duas cenas: destacar fecha a gaveta
/// e a janela continua o mesmo transcript, com os mesmos itens. Fechar a
/// janela não apaga nada — a conversa volta para a gaveta como estava.
///
/// Cena própria, como a 04 e a 05: ⌘W fecha, entra no menu Janela e sobrevive
/// à troca de aba Dashboard/Caixa/Agenda, porque não está dentro de nenhuma
/// delas. Uma só por app (`Window`, não `WindowGroup`): duas janelas da mesma
/// conversa seriam duas telas discordando sobre o que já foi executado.
public struct AssistantWindow: View {

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let session: AssistantSession

    @FocusState private var fieldFocused: Bool

    public init(session: AssistantSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let conversation = session.conversation {
                // O cabeçalho é o **do desenho**, e não o `WindowTitleBar`
                // genérico: é ele que traz o orbe, o "falando sobre … ·
                // trocar" e o nome do modelo na ponta direita. A gaveta usa a
                // mesma peça — ver `AssistantPresencaHeader`.
                AssistantPresencaHeader(
                    conversation: conversation,
                    context: session.chosenContext ?? .day,
                    width: AssistantDrawerMetrics.windowSize.width,
                    onSwapContext: {
                        session.chosenContext = AssistantDrawerCopy.toggled(
                            session.chosenContext ?? .day
                        )
                    },
                    trailing: { EmptyView() }
                )
                AssistantTranscript(
                    conversation: conversation,
                    session: session,
                    width: AssistantDrawerMetrics.windowSize.width,
                    // A execução é a **da janela principal**: a cena destacada
                    // não tem store nem fila, e um segundo caminho aqui
                    // divergiria do da gaveta no primeiro conserto.
                    onRun: session.run,
                    onReveal: session.reveal
                )
                .frame(maxHeight: .infinity)
                AssistantAskField(
                    conversation: conversation, focused: $fieldFocused, showsFooter: true
                )
            } else {
                semConversa
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.glassWindow.color)
        .task { fieldFocused = true }
        // A cena existe enquanto a janela existe. Ao fechar, a sessão volta a
        // dizer que não está destacada — e ⌘J volta a abrir a gaveta.
        .onDisappear { session.reattach() }
        .accessibilityIdentifier("assistant-window")
    }

    /// O vazio: o orbe em repouso e as duas linhas que dizem como começar.
    private var semConversa: some View {
        VStack(spacing: PresencaMetrics.workingGap) {
            AssistantOrb(side: PresencaMetrics.bigOrbCore)
            VStack(spacing: 6) {
                Text(L10n.tr("Nenhuma conversa ainda."))
                    .font(theme.sans.font(
                        size: PresencaMetrics.workingTitleSize, weight: .semibold
                    ))
                    .tracking(
                        PresencaMetrics.workingTitleSize * PresencaMetrics.workingTitleTracking
                    )
                    .foregroundStyle(theme.ink.color)
                Text(L10n.tr("Abra o assistente na janela principal com ⌘J e pergunte alguma coisa."))
                    .font(theme.sans.font(size: PresencaMetrics.proseSize))
                    .foregroundStyle(theme.ink3.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, PresencaMetrics.workingPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

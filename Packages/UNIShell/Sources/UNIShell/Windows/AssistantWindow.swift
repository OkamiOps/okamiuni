import SwiftUI
import UNICore
import UNIDesign

/// A janela destacada do assistente — `design/Mesa2.dc.html`, a janela de
/// 880 × 744 dos artboards `vazio`, `nota` e `trabalhando`.
///
/// **É a mesma conversa da gaveta**, e não uma segunda. Quem a segura é a
/// `AssistantSession`, que vive acima das duas cenas: destacar fecha a gaveta
/// e a janela continua o mesmo transcript, com os mesmos objetos. Fechar a
/// janela não apaga nada — a conversa volta para a gaveta como estava.
///
/// Cena própria, como a 04 e a 05: ⌘W fecha, entra no menu Janela e sobrevive
/// à troca de aba Dashboard/Caixa/Agenda, porque não está dentro de nenhuma
/// delas. Uma só por app (`Window`, não `WindowGroup`): duas janelas da mesma
/// conversa seriam duas telas discordando sobre o que já foi executado.
public struct AssistantWindow: View {

    @Environment(\.theme) private var theme

    let session: AssistantSession

    @FocusState private var fieldFocused: Bool

    public init(session: AssistantSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let conversation = session.conversation {
                // O cabeçalho é o **da Mesa**, e não o `WindowTitleBar`
                // genérico: é ele que traz o nome, a rota e o "trocar". Os
                // semáforos continuam sendo os do sistema, pela regra da casa.
                MesaWindowHeader(
                    conversation: conversation,
                    context: session.chosenContext ?? .day,
                    onSwapContext: {
                        session.chosenContext = AssistantDrawerCopy.toggled(
                            session.chosenContext ?? .day
                        )
                    }
                )
                AssistantMesa(
                    conversation: conversation,
                    session: session,
                    ownerName: session.ownerName,
                    // A execução é a **da janela principal**: a cena destacada
                    // não tem store nem fila, e um segundo caminho aqui
                    // divergiria do da gaveta no primeiro conserto.
                    onRun: session.run,
                    onReveal: session.reveal
                )
                .frame(maxHeight: .infinity)
                MesaAskField(conversation: conversation, focused: $fieldFocused)
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

    /// A mesa sem conversa nenhuma: as duas linhas que dizem como começar,
    /// sobre a superfície vazia.
    private var semConversa: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: MesaMetrics.greetingGap) {
                Text(L10n.tr("Nenhuma conversa ainda."))
                    .font(theme.sans.font(
                        size: MesaMetrics.greetingSize, weight: .bold
                    ))
                    .tracking(MesaMetrics.greetingSize * MesaMetrics.greetingTracking)
                    .foregroundStyle(theme.ink.color)
                Text(L10n.tr("Abra o assistente na janela principal com ⌘J e pergunte alguma coisa."))
                    .font(theme.sans.font(size: MesaMetrics.greetingSubSize))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MesaMetrics.greetingPadding.leading)
            .padding(.top, TrafficLightLayout.windowBarHeight)
            MesaDots()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
                .padding(.horizontal, MesaMetrics.mesaMargin.leading)
                .padding(.top, MesaMetrics.mesaMargin.top)
                .padding(.bottom, MesaMetrics.fieldMargin.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

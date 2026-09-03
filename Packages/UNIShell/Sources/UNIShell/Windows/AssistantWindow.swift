import SwiftUI
import UNICore
import UNIDesign

/// A janela destacada do assistente — `design/10-assistente-janela.dc.html`,
/// 460 × 620.
///
/// **É a mesma conversa da gaveta**, e não uma segunda. Quem a segura é a
/// `AssistantSession`, que vive acima das duas cenas: destacar fecha a gaveta
/// e a janela continua o mesmo transcript, com os mesmos cartões. Fechar a
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
            WindowTitleBar(title: AssistantDrawerCopy.title) {
                if let destino = session.conversation?.destination {
                    Text(destino.label)
                        .capsLabel(size: AssistantDrawerMetrics.capsSize)
                        .lineLimit(1)
                }
            }
            if let conversation = session.conversation {
                AssistantTranscript(
                    conversation: conversation,
                    session: session,
                    width: AssistantDrawerMetrics.windowSize.width,
                    padding: EdgeInsets(
                        top: AssistantDrawerMetrics.windowPadding,
                        leading: AssistantDrawerMetrics.windowPadding,
                        bottom: AssistantDrawerMetrics.windowPadding,
                        trailing: AssistantDrawerMetrics.windowPadding
                    ),
                    // A execução é a **da janela principal**: a cena destacada
                    // não tem store nem fila, e um segundo caminho aqui
                    // divergiria do da gaveta no primeiro conserto.
                    onRun: session.run,
                    onReveal: session.reveal
                )
                .frame(maxHeight: .infinity)
                AssistantAskField(
                    conversation: conversation, focused: $fieldFocused, showsFooter: false
                )
                .padding(.horizontal, AssistantDrawerMetrics.windowPadding)
                .padding(.top, AssistantDrawerMetrics.fieldPadding.top)
                .padding(.bottom, 16)
            } else {
                semConversa
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.surface.color)
        .task { fieldFocused = true }
        // A cena existe enquanto a janela existe. Ao fechar, a sessão volta a
        // dizer que não está destacada — e ⌘J volta a abrir a gaveta.
        .onDisappear { session.reattach() }
        .accessibilityIdentifier("assistant-window")
    }

    private var semConversa: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nenhuma conversa ainda.")
                .font(theme.sans.font(size: AssistantDrawerMetrics.turnTextSize, weight: .medium))
                .foregroundStyle(theme.ink.color)
            Text("Abra o assistente na janela principal com ⌘J e pergunte alguma coisa.")
                .font(theme.sans.font(size: AssistantDrawerMetrics.cardTextSize))
                .foregroundStyle(theme.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AssistantDrawerMetrics.windowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

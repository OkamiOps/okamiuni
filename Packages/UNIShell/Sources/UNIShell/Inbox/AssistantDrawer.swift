import SwiftUI
import UNICore
import UNIDesign

/// As medidas da gaveta e da janela do assistente na direção **Mesa** —
/// `design/Mesa2.dc.html`. Como o `DashboardMetrics`, mora **fora** da
/// `View`: uma `View` é `@MainActor` implícito e um `static` lá dentro estoura
/// quando um teste `nonisolated` o lê.
enum AssistantDrawerMetrics {

    /// `width: 400px` da gaveta no desenho (`aside` do estado `gaveta`).
    static let width: CGFloat = 400
    /// "fundo atrás a 45%" — o véu do desenho (`scrim`).
    static let backdropOpacity: Double = 0.45
    /// `box-shadow: -24px 0 60px rgba(0,0,0,.5)`.
    static let shadowRadius: CGFloat = 30
    static let shadowX: CGFloat = -24
    static let shadowOpacity: Double = 0.5

    /// A janela própria do desenho: `880 × 744`.
    static let windowSize = MesaMetrics.windowSize

    /// O botão ↑ do campo na janela.
    static let sendButtonSide: CGFloat = MesaMetrics.sendSide

    /// O deslize da gaveta. Curto, e só isso: "sem efeito além disso".
    static let slide: Animation = .easeOut(duration: 0.18)
}

// MARK: - A gaveta

/// A gaveta do assistente, na direção **Mesa** — `design/Mesa2.dc.html`,
/// artboard `gaveta`.
///
/// **É overlay, e nada atrás dela se mexe.** O conteúdo da tela fica a 45% de
/// opacidade e no mesmo lugar: uma gaveta que empurra a caixa faz a pessoa
/// perder o parágrafo que estava lendo por ter feito uma pergunta.
///
/// O que ela mostra é a mesma mesa da janela, empilhada em 400: o histórico da
/// conversa como objetos, com as ações de cada um. Nenhum item executa
/// sozinho: nem por ⏎ no campo, que só manda a pergunta.
struct AssistantDrawer: View {

    @Environment(\.theme) private var theme

    let conversation: AssistantConversation
    let session: AssistantSession
    /// O contexto em uso agora, já resolvido.
    let context: AssistantDrawerContext
    /// O nome do herói do dia, para a primeira pergunta sugerida. `nil` sem herói.
    let heroName: String?
    let onSwapContext: () -> Void
    let onDetach: () -> Void
    let onClose: () -> Void
    let onRun: (AssistantProposalCard) -> Void
    let onReveal: (String) -> Void

    /// O foco vai para o campo ao abrir, e volta para onde estava ao fechar —
    /// quem devolve é `InboxScreen`, que sabe de onde veio.
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MesaDrawerHeader(
                context: context,
                onSwapContext: onSwapContext,
                onDetach: onDetach,
                onClose: onClose
            )
            AssistantMesa(
                conversation: conversation,
                session: session,
                ownerName: session.ownerName,
                heroName: heroName,
                compact: true,
                onRun: onRun,
                onReveal: onReveal
            )
            .frame(maxHeight: .infinity)
            MesaAskField(
                conversation: conversation, focused: $fieldFocused, compact: true
            )
        }
        .frame(width: AssistantDrawerMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.glassWindow.color)
        .hairline(theme.btnLine, edges: .leading)
        .shadow(
            color: .black.opacity(AssistantDrawerMetrics.shadowOpacity),
            radius: AssistantDrawerMetrics.shadowRadius,
            x: AssistantDrawerMetrics.shadowX,
            y: 0
        )
        // O foco vai para o campo ao abrir; ao fechar, volta para onde estava.
        .background(GuardaEDevolveOFoco())
        .accessibilityIdentifier("assistant-drawer")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Assistente"))
        .task { fieldFocused = true }
    }
}

// MARK: - O foco que volta

/// Guarda quem tinha o foco de teclado quando esta view apareceu e o devolve
/// quando ela sai.
///
/// Foco é AppKit, e não há como fazer isto só com `@FocusState`: o `FocusState`
/// da gaveta sabe **tirar** o foco de onde estava, e não sabe para onde
/// devolvê-lo. Sem isto, fechar a gaveta com Esc deixa a janela sem primeiro
/// respondedor — e a tecla seguinte não vai a lugar nenhum, que é a definição
/// de teclado morto.
///
/// A regra da devolução: só devolve se **a gaveta** ainda for a dona do foco.
/// Se a pessoa clicou noutro lugar antes de fechar, quem manda é o clique.
struct GuardaEDevolveOFoco: NSViewRepresentable {

    @MainActor
    final class Coordinator {
        weak var janela: NSWindow?
        weak var anterior: NSResponder?
        var guardou = false

        /// A conta, separada do AppKit para o teste poder aferi-la: devolve
        /// o foco a quem o tinha, a menos que ele já tenha ido para fora da
        /// gaveta.
        static func devolve(
            anterior: NSResponder?, atual: NSResponder?, dentroDaGaveta: Bool
        ) -> NSResponder? {
            guard let anterior, anterior !== atual, dentroDaGaveta else { return nil }
            return anterior
        }

        func devolveOFoco() {
            guard let janela else { return }
            let atual = janela.firstResponder
            let dentro = (atual as? NSView)?.isDescendant(of: janela.contentView ?? NSView())
                ?? (atual === janela)
            guard let alvo = Self.devolve(
                anterior: anterior, atual: atual, dentroDaGaveta: dentro
            ) else { return }
            janela.makeFirstResponder(alvo)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard !context.coordinator.guardou, let janela = nsView.window else { return }
        context.coordinator.guardou = true
        context.coordinator.janela = janela
        context.coordinator.anterior = janela.firstResponder
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.devolveOFoco() }
    }
}

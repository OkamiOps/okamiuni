import Foundation
import Observation
import SwiftUI
import UNICore
import UNIDesign

/// De que a gaveta está falando. É o `AssistantScope` visto de fora: o dia
/// inteiro, ou o email que está selecionado agora.
public enum AssistantDrawerContext: String, Sendable, Hashable, CaseIterable {
    case day
    case selectedEmail

    /// O que a linha "Falando sobre" escreve — as palavras do 09.
    public var label: String {
        switch self {
        case .day: "o seu dia"
        case .selectedEmail: "o email selecionado"
        }
    }
}

/// As decisões da gaveta que não são desenho — e por isso não moram numa
/// `View`, onde não teriam teste.
public enum AssistantDrawerCopy {

    public static let title = "Assistente"
    public static let placeholder = "Pergunte, ou mande fazer…"
    public static let contextPrefix = "Falando sobre"
    public static let swapLabel = "trocar"
    /// A promessa do rodapé, e a regra inteira do recurso numa linha.
    public static let footer = "Nada é executado sem o seu clique. Esc fecha · ⌘J abre."
    /// O que o cartão vira depois de executado, enquanto o desfazer existir.
    public static let done = "Feito"
    public static let undo = "Desfazer"

    /// Qual contexto vale.
    ///
    /// Sem escolha explícita, quem manda é a tela: com um email selecionado a
    /// pergunta é sobre ele, sem seleção é sobre o dia. "Trocar" grava uma
    /// escolha, e a escolha ganha — mas pedir "o email selecionado" sem email
    /// nenhum cairia num contexto vazio, e aí a tela ganha de volta.
    public static func context(
        chosen: AssistantDrawerContext?, hasSelection: Bool
    ) -> AssistantDrawerContext {
        switch chosen {
        case .day: return .day
        case .selectedEmail: return hasSelection ? .selectedEmail : .day
        case nil: return hasSelection ? .selectedEmail : .day
        }
    }

    /// O outro lado do "trocar".
    public static func toggled(_ current: AssistantDrawerContext) -> AssistantDrawerContext {
        current == .day ? .selectedEmail : .day
    }

    /// Os três chips de partida do 09.
    ///
    /// O primeiro nomeia **o herói do dia** quando há um: "Responde o Jack por
    /// mim" no mockup é o Jack porque o Jack é quem espera há sete dias, não
    /// porque "Jack" seja uma palavra do produto. Sem herói, a pergunta é a
    /// genérica — inventar um nome seria a tela mentindo sobre a caixa.
    public static func chips(heroName: String?) -> [String] {
        let primeiro = heroName.flatMap(firstName(of:))
        return [
            primeiro.map { "Responde o \($0) por mim" } ?? "Responde por mim o mais antigo",
            "O que vence amanhã?",
            "Resume o dia em 3 linhas",
        ]
    }

    /// O primeiro nome de quem assina. `nil` quando não sobra nome nenhum —
    /// um endereço cru não vira "Responde o no-reply por mim".
    public static func firstName(of display: String) -> String? {
        let limpo = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty, !limpo.contains("@") else { return nil }
        let primeiro = limpo.split(separator: " ").first.map(String.init) ?? limpo
        return primeiro.isEmpty ? nil : primeiro
    }
}

/// A sessão do assistente: a conversa, a gaveta e a janela destacada.
///
/// ## Por que existe, em vez de `@State` no `InboxScreen`
///
/// A janela destacada (10) é **cena própria** — ela não está dentro da árvore
/// do `InboxScreen`, e um `@State` de lá não a alcança. "A conversa é a mesma
/// nos dois lugares" só é verdade se a dona dela viver acima das duas: o app
/// cria uma sessão e a entrega à janela principal e à cena da janela.
///
/// A conversa em si continua sendo montada por quem tem o motor (a tela, que
/// conhece o store e o assistente): a sessão a **adota** na primeira vez e a
/// guarda depois disso — inclusive quando a aba Dashboard sai da árvore.
@MainActor
@Observable
public final class AssistantSession {

    public private(set) var conversation: AssistantConversation?
    /// A gaveta está aberta sobre a caixa.
    public private(set) var isDrawerOpen = false
    /// A conversa foi destacada para a janela própria. Destacar **fecha** a
    /// gaveta: duas cópias da mesma conversa na tela é a definição de
    /// duplicidade.
    public private(set) var isDetached = false
    /// A escolha explícita do "trocar", quando houve uma.
    public var chosenContext: AssistantDrawerContext?
    /// Os cartões já executados nesta sessão.
    public private(set) var doneCards: Set<String> = []
    /// Existe "Desfazer" na barra de retorno agora? É o que mantém o
    /// "Feito · Desfazer" do cartão de pé — prometer um desfazer que já sumiu
    /// é pior do que não prometer nenhum. Quem sabe é a janela principal, que
    /// desenha a barra; a janela destacada só lê.
    public var hasUndo = false

    /// Quem executa a leva de um cartão, e quem abre uma mensagem.
    ///
    /// A janela destacada é cena própria e não tem store, recibo nem fila —
    /// ela **não pode** ter um caminho de execução próprio, que divergiria do
    /// da gaveta no primeiro conserto. A janela principal instala os dois
    /// aqui, e as duas superfícies clicam no mesmo lugar. Sem eles instalados
    /// o cartão não executa: um botão mudo é melhor do que um botão que faz
    /// metade.
    @ObservationIgnored private var runner: ((AssistantProposalCard) -> Void)?
    @ObservationIgnored private var revealer: ((String) -> Void)?

    public func install(
        runner: @escaping (AssistantProposalCard) -> Void,
        reveal: @escaping (String) -> Void
    ) {
        self.runner = runner
        self.revealer = reveal
    }

    public func run(_ card: AssistantProposalCard) { runner?(card) }
    public func reveal(_ messageID: String) { revealer?(messageID) }

    public init(debugOpen: Bool = false, debugDetached: Bool = false) {
        self.isDrawerOpen = debugOpen
        self.isDetached = debugDetached
    }

    public func adopt(_ conversation: AssistantConversation) {
        if self.conversation == nil { self.conversation = conversation }
    }

    public func open() {
        guard !isDetached else { return }
        // A animação mora aqui, e não em quem chama: ⌘J chega pelo menu
        // principal, que não tem `View` para envolver a mudança.
        withAnimation(AssistantDrawerMetrics.slide) { isDrawerOpen = true }
    }

    public func close() {
        withAnimation(AssistantDrawerMetrics.slide) { isDrawerOpen = false }
    }

    /// ⌘J: abre se fechada, fecha se aberta. Com a janela destacada, ⌘J traz
    /// a janela à frente e não abre gaveta nenhuma — quem cuida disso é a
    /// tela, porque abrir cena é dela.
    public func toggle() {
        if isDrawerOpen { close() } else { open() }
    }

    public func detach() {
        isDetached = true
        withAnimation(AssistantDrawerMetrics.slide) { isDrawerOpen = false }
    }

    /// A janela fechou. **A conversa fica**: fechar a janela não apaga o que
    /// foi conversado.
    public func reattach() { isDetached = false }

    public func markDone(_ cardID: String) { doneCards.insert(cardID) }
    public func isDone(_ cardID: String) -> Bool { doneCards.contains(cardID) }
    /// O desfazer da barra sumiu: "Feito · Desfazer" deixa de fazer sentido e
    /// o cartão volta a ser um cartão.
    public func forgetDone() { doneCards.removeAll() }
}

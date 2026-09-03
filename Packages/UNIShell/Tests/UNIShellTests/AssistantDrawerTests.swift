import AppKit
import Foundation
import os
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

// MARK: - Espiões

/// A porta de envio. **Nada** desta tarefa pode encostar nela: a §4 proíbe a
/// IA de enviar, e o vocabulário do modelo nem sabe nomear o verbo.
private final class GavetaSendSpy: MailSendPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [OutgoingMessage] = []
    var sent: [OutgoingMessage] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }

    func send(_ message: OutgoingMessage) throws {
        lock.lock(); defer { lock.unlock() }
        _sent.append(message)
    }
}

@MainActor
private final class ComandoSpy {
    var comandos: [ContextCommand] = []
}

/// Um motor que devolve resposta **e** propostas, sem rede e sem modelo.
@MainActor
private func motorComPropostas(
    texto: String = "São 13 disparos. Nenhum pede resposta.",
    propostas: [AssistantProposal],
    contador: ContadorDeChamadas? = nil
) -> AssistantEngine {
    AssistantEngine(
        supportsDraftReply: false,
        answer: { _ in
            contador?.answer()
            return texto
        },
        answerWithProposals: { _ in
            contador?.comPropostas()
            return AssistantAnswer(text: texto, proposals: propostas)
        }
    )
}

private final class ContadorDeChamadas: Sendable {
    private let estado = OSAllocatedUnfairLock(initialState: (prosa: 0, cartoes: 0))
    var prosa: Int { estado.withLock { $0.prosa } }
    var cartoes: Int { estado.withLock { $0.cartoes } }
    func answer() { estado.withLock { $0.prosa += 1 } }
    func comPropostas() { estado.withLock { $0.cartoes += 1 } }
}

// MARK: - As decisões puras

@Suite("Gaveta do assistente · as decisões")
struct AssistantDrawerCopyTests {

    @Test("sem escolha, o contexto é o email selecionado quando há um")
    func contextFollowsTheScreen() {
        #expect(
            AssistantDrawerCopy.context(chosen: nil, hasSelection: true) == .selectedEmail
        )
        #expect(AssistantDrawerCopy.context(chosen: nil, hasSelection: false) == .day)
    }

    @Test("trocar grava a escolha, e a escolha ganha da tela")
    func theChoiceWins() {
        #expect(AssistantDrawerCopy.context(chosen: .day, hasSelection: true) == .day)
        #expect(
            AssistantDrawerCopy.context(chosen: .selectedEmail, hasSelection: true)
                == .selectedEmail
        )
    }

    /// Pedir "o email selecionado" sem email nenhum cairia num contexto
    /// vazio: aí a tela ganha de volta, e a linha diz a verdade.
    @Test("sem seleção, escolher o email cai de volta no dia")
    func choosingEmailWithoutOneFallsBack() {
        #expect(
            AssistantDrawerCopy.context(chosen: .selectedEmail, hasSelection: false) == .day
        )
    }

    @Test("as palavras da linha de contexto são as do 09")
    func contextWordsMatchTheMockup() {
        #expect(AssistantDrawerContext.day.label == "o seu dia")
        #expect(AssistantDrawerContext.selectedEmail.label == "o email selecionado")
        #expect(AssistantDrawerCopy.contextPrefix == "Falando sobre")
        #expect(AssistantDrawerCopy.swapLabel == "trocar")
    }

    @Test("o primeiro chip nomeia o herói do dia")
    func theFirstChipNamesTheHero() {
        #expect(
            AssistantDrawerCopy.chips(heroName: "Jack Whitmore").first
                == "Responde o Jack por mim"
        )
        #expect(
            AssistantDrawerCopy.chips(heroName: "Maria Exemplo").first
                == "Responde o Maria por mim"
        )
    }

    /// Sem herói não há nome, e inventar um seria a tela mentindo sobre a
    /// caixa. Um endereço cru também não vira nome.
    @Test("sem herói, e sem nome, o chip fica genérico")
    func withoutAHeroTheChipStaysGeneric() {
        #expect(
            AssistantDrawerCopy.chips(heroName: nil).first == "Responde por mim o mais antigo"
        )
        #expect(
            AssistantDrawerCopy.chips(heroName: "no-reply@abacus.ai").first
                == "Responde por mim o mais antigo"
        )
        #expect(AssistantDrawerCopy.firstName(of: "   ") == nil)
    }

    @Test("os três chips do 09 estão lá, nessa ordem")
    func theThreeChips() {
        #expect(AssistantDrawerCopy.chips(heroName: "Jack Whitmore") == [
            "Responde o Jack por mim",
            "O que vence amanhã?",
            "Resume o dia em 3 linhas",
        ])
    }

    @Test("o rodapé promete o que a tarefa inteira promete")
    func theFooterSaysTheRule() {
        #expect(
            AssistantDrawerCopy.footer
                == "Nada é executado sem o seu clique. Esc fecha · ⌘J abre."
        )
    }

    @Test("as medidas do 09 e do 10 saem dos desenhos")
    func metricsMatchTheDrawings() {
        #expect(AssistantDrawerMetrics.width == 440)
        #expect(AssistantDrawerMetrics.backdropOpacity == 0.45)
        #expect(AssistantDrawerMetrics.windowSize == CGSize(width: 460, height: 620))
        #expect(AssistantDrawerMetrics.fieldHeight == 40)
        #expect(AssistantDrawerMetrics.sendButtonSide == 28)
        #expect(AssistantDrawerMetrics.cardButtonHeight == 26)
    }
}

// MARK: - A sessão

@Suite("Sessão do assistente")
@MainActor
struct AssistantSessionTests {

    private func conversa() -> AssistantConversation {
        AssistantConversation(
            scope: .email, context: .init(subject: "Hoje"),
            destination: .init(label: "Codex · ChatGPT", detail: "", isLocal: false),
            engine: AssistantEngine(supportsDraftReply: false) { _ in "" }
        )
    }

    @Test("⌘J abre e fecha")
    func toggleOpensAndCloses() {
        let session = AssistantSession()
        #expect(!session.isDrawerOpen)
        session.toggle()
        #expect(session.isDrawerOpen)
        session.toggle()
        #expect(!session.isDrawerOpen)
    }

    /// Destacar fecha a gaveta: a mesma conversa em duas telas ao mesmo tempo
    /// é a definição de duplicidade.
    @Test("destacar fecha a gaveta, e a gaveta não reabre destacada")
    func detachingClosesTheDrawer() {
        let session = AssistantSession()
        session.open()
        session.detach()
        #expect(!session.isDrawerOpen)
        #expect(session.isDetached)
        session.open()
        #expect(!session.isDrawerOpen, "a gaveta abriu com a janela destacada")
    }

    /// Fechar a janela não apaga a conversa.
    @Test("a janela fecha e a conversa fica")
    func closingTheWindowKeepsTheConversation() {
        let session = AssistantSession()
        let c = conversa()
        session.adopt(c)
        session.detach()
        session.reattach()
        #expect(!session.isDetached)
        #expect(session.conversation === c)
    }

    @Test("a sessão adota uma conversa só — a segunda não troca a primeira")
    func adoptionHappensOnce() {
        let session = AssistantSession()
        let primeira = conversa()
        let segunda = conversa()
        session.adopt(primeira)
        session.adopt(segunda)
        #expect(session.conversation === primeira)
    }

    @Test("Feito · Desfazer só existe enquanto o desfazer existir")
    func doneNeedsTheReceipt() {
        let session = AssistantSession()
        session.markDone("t#0")
        #expect(session.isDone("t#0"))
        session.forgetDone()
        #expect(!session.isDone("t#0"))
    }

    /// Sem executor instalado, o cartão **não faz nada** — e não meio.
    @Test("sem executor instalado, clicar no cartão não faz nada")
    func withoutARunnerNothingHappens() {
        let session = AssistantSession()
        session.run(AssistantProposalCard(
            id: "x", text: "t", rationale: "", verb: "Arquivar",
            secondary: nil, secondaryMessageID: nil,
            effects: [.command(.move(messageID: "m1", to: .archived))]
        ))
        // Nenhuma explosão, nenhum efeito. O teste é o não-acontecimento.
        #expect(!session.isDone("x"))
    }

    @Test("a janela destacada clica no mesmo executor da gaveta")
    func theWindowUsesTheSameRunner() {
        let session = AssistantSession()
        var recebidos: [String] = []
        session.install(runner: { recebidos.append($0.id) }, reveal: { _ in })
        session.run(AssistantProposalCard(
            id: "t#0", text: "t", rationale: "", verb: "Arquivar",
            secondary: nil, secondaryMessageID: nil, effects: []
        ))
        #expect(recebidos == ["t#0"])
    }
}

// MARK: - A conversa carrega as propostas

@Suite("A conversa com propostas")
@MainActor
struct AssistantConversationProposalsTests {

    @Test("perguntar sai pela rota com propostas, e o turno as guarda")
    func askingCarriesProposals() async throws {
        let contador = ContadorDeChamadas()
        let conversa = AssistantConversation(
            scope: .email, context: .init(subject: "Hoje"),
            destination: .init(label: "Codex", detail: "", isLocal: false),
            engine: motorComPropostas(
                propostas: [AssistantProposal(
                    title: "13 emails vão para Arquivado. Dá para desfazer.",
                    actions: [.archive(messageID: "m1")],
                    rationale: "nenhum pede resposta"
                )],
                contador: contador
            )
        )
        conversa.ask("arquiva tudo que é disparo hoje")
        await conversa.waitForIdle()

        #expect(contador.cartoes == 1, "a pergunta não saiu pela rota com propostas")
        #expect(contador.prosa == 0, "a rota de prosa foi usada para uma pergunta")
        let resposta = try #require(conversa.messages.last)
        #expect(resposta.speaker == .assistant)
        #expect(resposta.proposals.count == 1)
        #expect(resposta.cards.count == 1)
        #expect(resposta.cards[0].verb == "Arquivar")
    }

    /// O briefing continua na rota de prosa: ele não propõe nada, e pedir
    /// cartões ali seria um formato a mais para o mesmo texto.
    @Test("o briefing continua saindo pela rota de prosa")
    func briefingStaysOnTheProseRoute() async throws {
        let contador = ContadorDeChamadas()
        let conversa = AssistantConversation(
            scope: .workspace, context: .init(subject: "Hoje"),
            destination: .init(label: "Codex", detail: "", isLocal: false),
            engine: motorComPropostas(propostas: [], contador: contador)
        )
        conversa.briefing()
        await conversa.waitForIdle()
        #expect(contador.prosa == 1)
        #expect(contador.cartoes == 0)
    }

    /// Um motor que não sabe propor devolve a resposta sem cartão nenhum, em
    /// vez de prometer um botão que não existe.
    @Test("motor sem propostas responde sem cartão")
    func anEngineWithoutProposalsDrawsNoCards() async throws {
        let conversa = AssistantConversation(
            scope: .email, context: .init(subject: "Hoje"),
            destination: .init(label: "Codex", detail: "", isLocal: false),
            engine: AssistantEngine(supportsDraftReply: false) { _ in "só prosa" }
        )
        conversa.ask("e aí?")
        await conversa.waitForIdle()
        let resposta = try #require(conversa.messages.last)
        #expect(resposta.text == "só prosa")
        #expect(resposta.cards.isEmpty)
    }
}

// MARK: - O foco que volta

@Suite("O foco volta ao fechar a gaveta")
@MainActor
struct FocoDaGavetaTests {

    @Test("devolve a quem tinha o foco")
    func returnsToThePreviousResponder() {
        let anterior = NSTextField()
        let daGaveta = NSTextField()
        #expect(
            GuardaEDevolveOFoco.Coordinator.devolve(
                anterior: anterior, atual: daGaveta, dentroDaGaveta: true
            ) === anterior
        )
    }

    /// Se a pessoa clicou noutro lugar antes de fechar, quem manda é o
    /// clique — devolver o foco por cima dele seria roubar o cursor.
    @Test("não devolve quando o foco já saiu da gaveta")
    func doesNotStealFocusBack() {
        let anterior = NSTextField()
        #expect(
            GuardaEDevolveOFoco.Coordinator.devolve(
                anterior: anterior, atual: NSTextField(), dentroDaGaveta: false
            ) == nil
        )
    }

    @Test("não devolve para quem já está com o foco")
    func doesNotFightItself() {
        let mesmo = NSTextField()
        #expect(
            GuardaEDevolveOFoco.Coordinator.devolve(
                anterior: mesmo, atual: mesmo, dentroDaGaveta: true
            ) == nil
        )
    }
}

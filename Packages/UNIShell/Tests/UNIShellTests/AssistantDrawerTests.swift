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
                == "Rascunhos são salvos durante o pedido. Envio exige revisão. Esc fecha · ⌘J abre."
        )
    }

    /// A mesma garantia de antes — as medidas saem do desenho e não do dedo —
    /// agora contra `Mesa2.dc.html`, que é o desenho aprovado: janela de
    /// 880 × 744, gaveta de 400, botão ↑ de 30 e campo com
    /// `padding: 10px 10px 10px 14px` numa margem de `12px 16px 16px`.
    @Test("as medidas da Mesa saem do desenho")
    func metricsMatchTheDrawings() {
        #expect(AssistantDrawerMetrics.width == 400)
        #expect(AssistantDrawerMetrics.backdropOpacity == 0.45)
        #expect(AssistantDrawerMetrics.windowSize == CGSize(width: 880, height: 744))
        #expect(AssistantDrawerMetrics.sendButtonSide == 30)
        #expect(MesaMetrics.greetingSize == 22)
        #expect(MesaMetrics.greetingPadding.leading == 28)
        #expect(MesaMetrics.mesaMargin.leading == 16)
        #expect(MesaMetrics.dotSpacing == 22)
        #expect(MesaMetrics.objectMaxWidth == 560)
        #expect(MesaMetrics.fieldPadding.leading == 14)
        #expect(MesaMetrics.fieldMargin.leading == 16)
        #expect(MesaMetrics.askedMaxWidth == 440)
        #expect(MesaMetrics.capsSize == 10)
        #expect(MesaMetrics.drawerSendSide == 28)
        #expect(MesaMetrics.drawerHeaderPadding.leading == 18)
    }

    /// O cabeçalho da janela da Mesa **não** regride os semáforos: a altura é
    /// a da casa e o conteúdo começa depois da fileira. Foi o conserto de duas
    /// rejeições, e um número escrito à mão aqui o desfaria.
    @Test("o cabeçalho da janela usa a régua dos semáforos, e não a do desenho")
    func theWindowHeaderKeepsTheTrafficLightRule() {
        #expect(TrafficLightLayout.windowBarHeight == 52)
        // O recuo é o fim da fileira mais a folga: a conta é a da casa, e não
        // um número solto. Se ela mudar, muda para todas as janelas próprias.
        #expect(
            TrafficLightLayout.windowContentInset
                == TrafficLightLayout.windowRowLeading
                    + TrafficLightLayout.windowRowSpacing * 2 + 14 + 14
        )
        #expect(TrafficLightLayout.windowContentInset > TrafficLightLayout.windowRowLeading)
    }
}

// MARK: - Os objetos da mesa

@Suite("Os objetos da Mesa")
struct MesaObjectTests {

    private func card(
        id: String = "t#0", text: String = "Marina espera o seu ok",
        verb: String = "Responder",
        effects: [AssistantProposalCard.Effect]
    ) -> AssistantProposalCard {
        AssistantProposalCard(
            id: id, text: text, rationale: "ela espera desde ontem", verb: verb,
            secondary: "Ver", secondaryMessageID: "marina", effects: effects
        )
    }

    /// **O efeito decide o objeto, não o verbo.** É o efeito que diz o que o
    /// clique faz, e o botão primário tem de dizer a verdade sobre ele.
    @Test("um cartão que prepara resposta é um rascunho")
    func prepareReplyBecomesADraft() throws {
        let objeto = MesaObject.kind(
            for: card(effects: [.prepareReply(messageID: "marina", draft: "Marina, fechado.")]),
            id: "t#0"
        )
        guard case let .draft(_, texto, cartao) = objeto else {
            Issue.record("não virou rascunho: \(objeto)")
            return
        }
        #expect(texto == "Marina, fechado.")
        #expect(cartao != nil, "o rascunho perdeu o cartão, e com ele o compositor")
    }

    /// Um rascunho **vazio** não é rascunho: um objeto com corpo em branco e
    /// um botão "Abrir no compositor" abriria uma janela com nada dentro.
    @Test("rascunho vazio cai em proposta")
    func anEmptyDraftIsNotADraft() {
        let objeto = MesaObject.kind(
            for: card(effects: [.prepareReply(messageID: "marina", draft: "   ")]),
            id: "t#0"
        )
        if case .proposal = objeto {} else { Issue.record("não virou proposta: \(objeto)") }
    }

    @Test("agenda e bloco viram evento")
    func agendaWritesBecomeEvents() {
        for efeito in [
            AssistantProposalCard.Effect.addToAgenda(messageID: "marina"),
            .reserveBlock(day: 0, startMinute: 900, minutes: 30, title: "Responder"),
        ] {
            let objeto = MesaObject.kind(for: card(effects: [efeito]), id: "t#0")
            if case .event = objeto {} else { Issue.record("não virou evento: \(objeto)") }
        }
    }

    @Test("arquivar continua sendo proposta")
    func archivingStaysAProposal() {
        let objeto = MesaObject.kind(
            for: card(effects: [.command(.move(messageID: "marina", to: .archived))]),
            id: "t#0"
        )
        if case .proposal = objeto {} else { Issue.record("não virou proposta: \(objeto)") }
    }

    /// A mesa é a conversa inteira, na ordem: a pergunta, a nota, e os objetos
    /// que a resposta trouxe.
    @Test("a mesa monta pergunta, nota e objetos na ordem")
    func theTableKeepsTheOrder() {
        let pergunta = AssistantMessage(speaker: .user, text: "e a Marina?")
        let resposta = AssistantMessage(
            speaker: .assistant,
            text: "Ela espera o seu ok.",
            proposals: [
                AssistantProposal(
                    title: "Responder a Marina",
                    actions: [.reply(messageID: "marina", draft: "Marina, fechado.")],
                    rationale: "ela espera desde ontem"
                ),
                AssistantProposal(
                    title: "Call com a Marina às 15h",
                    actions: [.addToAgenda(messageID: "marina")],
                    rationale: "em 40 minutos"
                ),
            ]
        )
        let mesa = MesaObject.table(for: [pergunta, resposta], lastReceipt: nil)
        #expect(mesa.count == 4)
        if case .asked = mesa[0] {} else { Issue.record("o primeiro não é a pergunta") }
        if case .note = mesa[1] {} else { Issue.record("o segundo não é a nota") }
        if case .draft = mesa[2] {} else { Issue.record("o terceiro não é o rascunho") }
        if case .event = mesa[3] {} else { Issue.record("o quarto não é o evento") }
    }

    /// O recibo é da **última** ida: pendurá-lo num turno antigo faria a tela
    /// dizer que aqueles passos aconteceram agora.
    @Test("o recibo só pendura na última resposta")
    func theReceiptOnlyHangsOnTheLastAnswer() {
        let recibo = AssistantRunReceipt(steps: ["li 12 e-mails de hoje"], elapsed: 2.4)
        let mesa = MesaObject.table(
            for: [
                AssistantMessage(speaker: .user, text: "a"),
                AssistantMessage(speaker: .assistant, text: "primeira"),
                AssistantMessage(speaker: .user, text: "b"),
                AssistantMessage(speaker: .assistant, text: "segunda"),
            ],
            lastReceipt: recibo
        )
        var comRecibo: [String] = []
        for objeto in mesa {
            if case let .note(_, texto, r) = objeto, r != nil { comRecibo.append(texto) }
        }
        #expect(comRecibo == ["segunda"])
    }

    /// **Sem dia, a mesa não inventa dia.** É o caso que separa "a mesa está
    /// limpa" de "a mesa mente": o construtor devolve vazio, e é a tela que
    /// troca a segunda linha e sobe as sugestões.
    @Test("sem nada no dia, a mesa não monta objeto nenhum")
    func anEmptyDayBuildsNoObjects() {
        let itens = MesaDayItem.items(
            plan: DayPlan(
                hero: nil, sections: [], counts: [:], removed: [], replyBlock: nil
            ),
            agenda: [], pending: [],
            today: Date(timeIntervalSince1970: 1_767_196_920), nowMinute: 600
        )
        #expect(itens.isEmpty)
    }

    /// A promessa sem prazo vai para o fim: o e-mail não disse quando, e
    /// ordená-la como "hoje" seria inventar o prazo dela.
    @Test("a promessa que vence primeiro ganha, e a sem prazo fica por último")
    func theSoonestPromiseWins() throws {
        let hoje = Date(timeIntervalSince1970: 1_767_196_920)
        let itens = MesaDayItem.items(
            plan: DayPlan(
                hero: nil, sections: [], counts: [:], removed: [], replyBlock: nil
            ),
            agenda: [],
            pending: [
                PendingItem(id: "sem", text: "Sem prazo nenhum", accountID: "a"),
                PendingItem(
                    id: "perto", text: "Mandar a proposta para o Rafa",
                    accountID: "a", dueDate: hoje.addingTimeInterval(3_600)
                ),
                PendingItem(
                    id: "longe", text: "Liberar o Tally público",
                    accountID: "a", dueDate: hoje.addingTimeInterval(400_000)
                ),
            ],
            today: hoje, nowMinute: 600
        )
        let promessa = try #require(itens.first)
        #expect(promessa.kind == .promise)
        #expect(promessa.id == "promise:perto")
        #expect(promessa.messageID == nil, "promessa não tem e-mail para o Ver abrir")
    }

    /// Um compromisso que já acabou não é "o próximo".
    @Test("o compromisso do dia é o próximo que ainda não acabou")
    func theMeetingIsTheNextOneStillRunning() throws {
        let hoje = Date(timeIntervalSince1970: 1_767_196_920)
        let itens = MesaDayItem.items(
            plan: DayPlan(
                hero: nil, sections: [], counts: [:], removed: [], replyBlock: nil
            ),
            agenda: [
                AgendaItem(
                    id: "passado", title: "Daily", startMinute: 540,
                    endMinute: 560, accountID: "a"
                ),
                AgendaItem(
                    id: "proximo", title: "Call com Jayden", startMinute: 900,
                    endMinute: 930, accountID: "a"
                ),
                AgendaItem(
                    id: "amanha", title: "Retro", startMinute: 600,
                    endMinute: 630, accountID: "a", dayOffset: 1
                ),
            ],
            pending: [], today: hoje, nowMinute: 860
        )
        let reuniao = try #require(itens.first)
        #expect(reuniao.kind == .meeting)
        #expect(reuniao.id == "meeting:proximo")
        // 900 − 860 = 40 minutos, que é o que o desenho escreve.
        #expect(reuniao.caps.contains("40"), "o versalete não contou os minutos: \(reuniao.caps)")
    }

    /// Nunca mais de três: o desenho tem três objetos, e uma mesa com sete
    /// deixa de ser "o que não pode esperar".
    @Test("a mesa posta para em três objetos")
    func theTableStopsAtThree() {
        let hoje = Date(timeIntervalSince1970: 1_767_196_920)
        let itens = MesaDayItem.items(
            plan: DayPlan(
                hero: nil, sections: [], counts: [:], removed: [], replyBlock: nil
            ),
            agenda: [AgendaItem(
                id: "m", title: "Call", startMinute: 900, endMinute: 930, accountID: "a"
            )],
            pending: (0..<9).map {
                PendingItem(
                    id: "p\($0)", text: "Promessa \($0)", accountID: "a",
                    dueDate: hoje.addingTimeInterval(Double($0) * 3_600)
                )
            },
            today: hoje, nowMinute: 860
        )
        #expect(itens.count <= 3)
    }

    /// Um turno de `draftReply` não tem cartão — e por isso não promete
    /// compositor nenhum. Sobra o texto e o "Copiar".
    @Test("um turno de rascunho sem cartão não promete compositor")
    func aDraftTurnWithoutACardPromisesNoComposer() {
        let mesa = MesaObject.table(
            for: [AssistantMessage(
                speaker: .assistant, text: "Marina, fechado.", kind: .draft
            )],
            lastReceipt: nil
        )
        guard case let .draft(_, _, cartao) = mesa[0] else {
            Issue.record("não virou rascunho")
            return
        }
        #expect(cartao == nil)
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

    /// "Desfazer" vale para **o recibo da leva do cartão**. Um recibo de
    /// outra origem (a mensagem que a pessoa apagou antes) não o mantém de
    /// pé, e o "Feito" fica de qualquer jeito: a leva foi executada.
    @Test("Desfazer só existe enquanto o recibo da própria leva existir")
    func doneNeedsItsOwnReceipt() {
        let session = AssistantSession()
        let daLeva = UUID()
        session.markDone("t#0", undoing: daLeva)
        #expect(session.isDone("t#0"))
        #expect(session.hasUndo)

        session.receiptChanged(to: daLeva)
        #expect(session.hasUndo, "o recibo da própria leva derrubou o Desfazer")

        session.receiptChanged(to: UUID())
        #expect(!session.hasUndo, "um recibo de outra origem virou o Desfazer do cartão")
        #expect(session.isDone("t#0"), "o cartão executado voltou a ser botão")

        session.receiptChanged(to: nil)
        #expect(!session.hasUndo)
    }

    /// Uma leva sem volta (uma reserva de bloco) diz "Feito" e nada mais —
    /// mesmo com um recibo de outra coisa de pé na barra.
    @Test("leva sem volta não promete Desfazer")
    func anUnundoableBatchNeverPromisesUndo() {
        let session = AssistantSession()
        session.markDone("t#0", undoing: nil)
        #expect(session.isDone("t#0"))
        #expect(!session.hasUndo)
        session.receiptChanged(to: UUID())
        #expect(!session.hasUndo, "o cartão herdou o Desfazer de outra ação")
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

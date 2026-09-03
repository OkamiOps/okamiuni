import Foundation
import GRDB
import Testing
import UNICore

@testable import UNISync

@Suite("A fila do rascunho antecipado")
struct ReadyDraftCoordinatorTests {

    // MARK: - Cenário

    private static let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private func settings(
        _ settings: AssistantSettings = AssistantSettings()
    ) throws -> AssistantSettingsStore {
        let suite = "okamiuni.ready-draft.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = AssistantSettingsStore(defaults: defaults, key: "assistant")
        try store.save(settings)
        return store
    }

    private func coordinator(
        database: SyncDatabase,
        assistant: any TextAssisting,
        settingsStore: AssistantSettingsStore,
        agenda: [AgendaItem] = []
    ) -> ReadyDraftCoordinator {
        ReadyDraftCoordinator(
            database: database,
            assistant: assistant,
            settingsStore: settingsStore,
            agenda: { agenda },
            now: { Self.agora },
            nowMinute: { 600 }
        )
    }

    private let pedeResposta = MessageTriage(
        needsReply: true, intent: .request, urgency: .normal
    )

    // MARK: - A fila não lê o acervo inteiro

    /// **A consulta tem `LIMIT`.** Sem ele, cada tique da observação (que
    /// acorda a cada mudança de corpo, triagem ou rascunho) trazia todos os
    /// corpos `needsReply` do acervo para usar vinte (I3 da revisão final).
    @Test("uma página da fila nunca traz mais linhas do que o pedido")
    func onePageNeverReadsMoreThanAsked() async throws {
        let banco = try SyncDatabase.temporary()
        for n in 1...12 {
            try Fixture.escreveMensagem(
                in: banco.pool, id: "m\(n)",
                recebidaEm: Self.agora.addingTimeInterval(TimeInterval(-n * 60))
            )
            try Fixture.escreveTriagem(in: banco.pool, id: "m\(n)", triage: pedeResposta)
        }
        let fila = coordinator(
            database: banco, assistant: EspiaoDeRascunho(resposta: "x"),
            settingsStore: try settings()
        )
        let pagina = try fila.pendingRows(limit: 4, offset: 0)
        #expect(pagina.count == 4, "a página trouxe \(pagina.count) linhas para um limite de 4")
    }

    /// E o `LIMIT` **não** pode fazer a fila morrer de fome: as mais recentes
    /// podem ser todas puláveis (disparo em massa), e o trabalho de verdade
    /// estar logo atrás delas. A fila avança de página até encher o lote.
    @Test("com as recentes todas puláveis, a fila ainda acha o trabalho atrás")
    func pagingSurvivesASkippedFront() async throws {
        let banco = try SyncDatabase.temporary()
        // Mais disparos do que uma página inteira: a primeira volta da fila
        // não pode achar nada e desistir.
        for n in 1...(ReadyDraftCoordinator.pageSize + 5) {
            try Fixture.escreveMensagem(
                in: banco.pool, id: "disparo\(n)",
                recebidaEm: Self.agora.addingTimeInterval(TimeInterval(-n * 60)),
                marks: .listUnsubscribe
            )
            try Fixture.escreveTriagem(
                in: banco.pool, id: "disparo\(n)", triage: pedeResposta
            )
        }
        try Fixture.escreveMensagem(
            in: banco.pool, id: "gente",
            recebidaEm: Self.agora.addingTimeInterval(-3_600)
        )
        try Fixture.escreveTriagem(in: banco.pool, id: "gente", triage: pedeResposta)

        let fila = coordinator(
            database: banco, assistant: EspiaoDeRascunho(resposta: "Consigo terça."),
            settingsStore: try settings()
        )
        let trabalho = try await fila.pendingWork(limit: 2)
        #expect(
            trabalho.map(\.message.id) == ["gente"],
            "a fila parou na primeira página e não achou quem precisa de resposta"
        )
    }

    // MARK: - Quem entra na fila

    @Test("gera para quem precisa de resposta e não é disparo")
    func draftsWhatNeedsAReply() async throws {
        let banco = try SyncDatabase.temporary()
        let mensagem = try Fixture.escreveMensagem(in: banco.pool, id: "m1")
        try Fixture.escreveTriagem(in: banco.pool, id: "m1", triage: pedeResposta)
        let motor = EspiaoDeRascunho(resposta: "Consigo terça, Jack.")

        let fila = coordinator(
            database: banco, assistant: motor, settingsStore: try settings()
        )
        #expect(await fila.processPending() == 1)

        let guardados = try ReadyDraftStore(database: banco).drafts(for: ["m1"])
        #expect(guardados["m1"]?.text == "Consigo terça, Jack.")
        #expect(guardados["m1"]?.matches(mensagem) == true)
        #expect(guardados["m1"]?.usedAgenda == false)
        #expect(motor.calls == 1)
    }

    @Test("não gera para disparo em massa, mesmo com needsReply")
    func skipsBulk() async throws {
        let banco = try SyncDatabase.temporary()
        try Fixture.escreveMensagem(in: banco.pool, id: "m1", marks: .listUnsubscribe)
        try Fixture.escreveTriagem(in: banco.pool, id: "m1", triage: pedeResposta)
        let motor = EspiaoDeRascunho(resposta: "Não deveria existir.")

        let fila = coordinator(
            database: banco, assistant: motor, settingsStore: try settings()
        )
        #expect(await fila.processPending() == 0)
        #expect(motor.calls == 0)
        #expect(try ReadyDraftStore(database: banco).drafts(for: ["m1"]).isEmpty)
    }

    @Test("sem needsReply não há rascunho para escrever")
    func skipsWhatDoesNotNeedAReply() async throws {
        let banco = try SyncDatabase.temporary()
        try Fixture.escreveMensagem(in: banco.pool, id: "m1")
        try Fixture.escreveTriagem(
            in: banco.pool, id: "m1",
            triage: MessageTriage(needsReply: false, intent: .newsletter, urgency: .low)
        )
        let motor = EspiaoDeRascunho(resposta: "Não deveria existir.")
        let fila = coordinator(
            database: banco, assistant: motor, settingsStore: try settings()
        )
        #expect(await fila.processPending() == 0)
        #expect(motor.calls == 0)
    }

    @Test("não regera para o mesmo hash")
    func doesNotRewriteTheSameHash() async throws {
        let banco = try SyncDatabase.temporary()
        try Fixture.escreveMensagem(in: banco.pool, id: "m1")
        try Fixture.escreveTriagem(in: banco.pool, id: "m1", triage: pedeResposta)
        let motor = EspiaoDeRascunho(resposta: "Consigo terça.")
        let fila = coordinator(
            database: banco, assistant: motor, settingsStore: try settings()
        )

        #expect(await fila.processPending() == 1)
        #expect(await fila.processPending() == 0)
        #expect(motor.calls == 1)
    }

    @Test("o corpo muda, o rascunho é reescrito")
    func rewritesWhenTheBodyChanges() async throws {
        let banco = try SyncDatabase.temporary()
        try Fixture.escreveMensagem(in: banco.pool, id: "m1")
        try Fixture.escreveTriagem(in: banco.pool, id: "m1", triage: pedeResposta)
        let motor = EspiaoDeRascunho(resposta: "Primeira resposta.")
        let fila = coordinator(
            database: banco, assistant: motor, settingsStore: try settings()
        )
        #expect(await fila.processPending() == 1)

        try await banco.pool.write { db in
            try db.execute(
                sql: "UPDATE message_body SET paragraphs = ?, plain = ? WHERE messageID = 'm1'",
                arguments: ["[\"Outro corpo, outra pergunta.\"]", "Outro corpo, outra pergunta."]
            )
        }
        motor.resposta = "Segunda resposta."
        #expect(await fila.processPending() == 1)
        #expect(motor.calls == 2)
        #expect(
            try ReadyDraftStore(database: banco).drafts(for: ["m1"])["m1"]?.text
                == "Segunda resposta."
        )
    }

    @Test("descartar não regera — o botão descarta de verdade")
    func discardStopsTheQueue() async throws {
        let banco = try SyncDatabase.temporary()
        try Fixture.escreveMensagem(in: banco.pool, id: "m1")
        try Fixture.escreveTriagem(in: banco.pool, id: "m1", triage: pedeResposta)
        let motor = EspiaoDeRascunho(resposta: "Consigo terça.")
        let loja = ReadyDraftStore(database: banco)
        let fila = coordinator(
            database: banco, assistant: motor, settingsStore: try settings()
        )
        #expect(await fila.processPending() == 1)

        try loja.discard(messageID: "m1")
        #expect(await fila.processPending() == 0)
        #expect(motor.calls == 1)
        #expect(try loja.drafts(for: ["m1"]).isEmpty)
    }

    @Test("descartado continua descartado quando o motor troca de versão")
    func discardSurvivesANewModel() async throws {
        let banco = try SyncDatabase.temporary()
        try Fixture.escreveMensagem(in: banco.pool, id: "m1")
        try Fixture.escreveTriagem(in: banco.pool, id: "m1", triage: pedeResposta)
        let loja = ReadyDraftStore(database: banco)
        let configuracao = try settings()
        #expect(
            await coordinator(
                database: banco, assistant: EspiaoDeRascunho(resposta: "Consigo terça."),
                settingsStore: configuracao
            ).processPending() == 1
        )
        try loja.discard(messageID: "m1")

        // Um motor novo é motivo para reescrever o que a pessoa **não**
        // recusou. O que ela recusou continua recusado: a decisão foi sobre
        // esta versão da mensagem, não sobre quem escreveu.
        let novoMotor = EspiaoDeRascunho(resposta: "Outro motor, mesma recusa.")
        novoMotor.versao = "espiao/rascunho-v2"
        let fila = coordinator(
            database: banco, assistant: novoMotor, settingsStore: configuracao
        )
        #expect(await fila.processPending() == 0)
        #expect(novoMotor.calls == 0)
        #expect(try loja.drafts(for: ["m1"]).isEmpty)
    }

    @Test("resposta vazia do motor não vira rascunho")
    func emptyAnswerIsNotADraft() async throws {
        let banco = try SyncDatabase.temporary()
        try Fixture.escreveMensagem(in: banco.pool, id: "m1")
        try Fixture.escreveTriagem(in: banco.pool, id: "m1", triage: pedeResposta)
        let motor = EspiaoDeRascunho(resposta: "   \n  ")
        let fila = coordinator(
            database: banco, assistant: motor, settingsStore: try settings()
        )
        #expect(await fila.processPending() == 0)
        #expect(try ReadyDraftStore(database: banco).drafts(for: ["m1"]).isEmpty)
    }

    @Test("motor novo, rascunho novo — a versão faz parte da validade")
    func rewritesWhenTheModelChanges() async throws {
        let banco = try SyncDatabase.temporary()
        try Fixture.escreveMensagem(in: banco.pool, id: "m1")
        try Fixture.escreveTriagem(in: banco.pool, id: "m1", triage: pedeResposta)
        let loja = ReadyDraftStore(database: banco)
        let registro = try await banco.pool.read { db in
            try MessageRecord.fetchOne(db, key: "m1")
        }
        let mensagem = try #require(registro).message(body: ["Corpo da mensagem."])
        try loja.save(
            ReadyDraft(
                messageID: "m1", text: "Escrito por um motor antigo.",
                contentHash: ReadyDraft.contentHash(for: mensagem),
                modelVersion: "motor/antigo"
            )
        )

        let motor = EspiaoDeRascunho(resposta: "Escrito pelo motor de agora.")
        let fila = coordinator(
            database: banco, assistant: motor, settingsStore: try settings()
        )
        #expect(await fila.processPending() == 1)
        #expect(try loja.drafts(for: ["m1"])["m1"]?.text == "Escrito pelo motor de agora.")
    }

    // MARK: - O consentimento

    private var remoto: AssistantSettings {
        AssistantSettings(
            provider: .openAICompatible,
            openAICompatible: .init(
                endpoint: "https://api.exemplo.com/v1", model: "m",
                credentialID: "primary", authenticationMode: .none
            )
        )
    }

    @Test("provedor remoto sem opt-in: não gera, não trava, não conta falta")
    func remoteWithoutOptInDoesNothing() async throws {
        let banco = try SyncDatabase.temporary()
        try Fixture.escreveMensagem(in: banco.pool, id: "m1")
        try Fixture.escreveTriagem(in: banco.pool, id: "m1", triage: pedeResposta)
        let motor = EspiaoDeRascunho(resposta: "Não pode sair daqui.")

        var configuracao = remoto
        configuracao.automaticAnalysis = .onDeviceOnly
        let fila = coordinator(
            database: banco, assistant: motor, settingsStore: try settings(configuracao)
        )

        #expect(await fila.processPending() == 0)
        #expect(motor.calls == 0)
        // Três rodadas e a fila continua correndo: "sem opt-in" é o estado
        // normal, não uma falha para pausar em cima.
        _ = await fila.processPending()
        _ = await fila.processPending()
        #expect(await fila.queueState() == .running)
    }

    @Test("provedor remoto com opt-in: a mensagem anterior ao carimbo fica")
    func remoteOptInCoversOnlyWhatCameAfter() async throws {
        let banco = try SyncDatabase.temporary()
        // Chegou uma hora antes do clique.
        try Fixture.escreveMensagem(
            in: banco.pool, id: "antiga",
            recebidaEm: Self.agora.addingTimeInterval(-3_600)
        )
        try Fixture.escreveTriagem(in: banco.pool, id: "antiga", triage: pedeResposta)
        try Fixture.escreveMensagem(
            in: banco.pool, id: "nova",
            recebidaEm: Self.agora.addingTimeInterval(3_600)
        )
        try Fixture.escreveTriagem(in: banco.pool, id: "nova", triage: pedeResposta)

        var configuracao = remoto
        configuracao.automaticAnalysis = .configuredProvider
        configuracao.automaticAnalysisSince = Self.agora
        let motor = EspiaoDeRascunho(resposta: "Resposta remota.")
        let fila = coordinator(
            database: banco, assistant: motor, settingsStore: try settings(configuracao)
        )

        #expect(await fila.processPending() == 1)
        let guardados = try ReadyDraftStore(database: banco).drafts(for: ["antiga", "nova"])
        #expect(guardados.keys.sorted() == ["nova"])
        #expect(await fila.queueState() == .running)
    }

    @Test("a data do cabeçalho no futuro não fura o carimbo do opt-in")
    func remoteOptInUsesWhenTheMessageArrivedHere() async throws {
        let banco = try SyncDatabase.temporary()
        // O `Date:` diz que ela é de amanhã; ela está neste Mac desde ontem.
        // Quem manda é a segunda data — senão um relógio errado (ou um
        // spammer de propósito) manda para o provedor o que já estava aqui
        // antes do clique.
        try Fixture.escreveMensagem(
            in: banco.pool, id: "m1",
            recebidaEm: Self.agora.addingTimeInterval(86_400),
            vistaEm: Self.agora.addingTimeInterval(-86_400)
        )
        try Fixture.escreveTriagem(in: banco.pool, id: "m1", triage: pedeResposta)

        var configuracao = remoto
        configuracao.automaticAnalysis = .configuredProvider
        configuracao.automaticAnalysisSince = Self.agora
        let motor = EspiaoDeRascunho(resposta: "Não pode sair daqui.")
        let fila = coordinator(
            database: banco, assistant: motor, settingsStore: try settings(configuracao)
        )

        #expect(await fila.processPending() == 0)
        #expect(motor.calls == 0)
    }

    // MARK: - A agenda

    @Test("marcação de horário recebe as folgas e grava usedAgenda")
    func schedulingUsesTheAgenda() async throws {
        let banco = try SyncDatabase.temporary()
        try Fixture.escreveMensagem(in: banco.pool, id: "m1")
        try Fixture.escreveTriagem(
            in: banco.pool, id: "m1",
            triage: MessageTriage(needsReply: true, intent: .scheduling, urgency: .normal)
        )
        let motor = EspiaoDeRascunho(resposta: "Consigo na terça, 15h.")
        let fila = coordinator(
            database: banco, assistant: motor, settingsStore: try settings(),
            agenda: [
                AgendaItem(
                    id: "a1", title: "Reunião",
                    startMinute: 600, endMinute: 660, accountID: "conta-a", dayOffset: 0
                )
            ]
        )

        #expect(await fila.processPending() == 1)
        let guardado = try ReadyDraftStore(database: banco).drafts(for: ["m1"])["m1"]
        #expect(guardado?.usedAgenda == true)
        // A folga entrou no pedido, em português e com o dia por extenso.
        #expect(motor.ultimoTexto.contains("Minha disponibilidade"))
        #expect(motor.ultimoTexto.contains("11h–18h"))
    }

    @Test("o texto pedindo disponibilidade também abre a agenda")
    func availabilityQuestionUsesTheAgenda() async throws {
        let banco = try SyncDatabase.temporary()
        try Fixture.escreveMensagem(
            in: banco.pool, id: "m1",
            corpo: ["Qual a sua disponibilidade esta semana?"]
        )
        try Fixture.escreveTriagem(in: banco.pool, id: "m1", triage: pedeResposta)
        let motor = EspiaoDeRascunho(resposta: "Terça de tarde.")
        let fila = coordinator(
            database: banco, assistant: motor, settingsStore: try settings()
        )

        #expect(await fila.processPending() == 1)
        #expect(
            try ReadyDraftStore(database: banco).drafts(for: ["m1"])["m1"]?.usedAgenda == true
        )
    }

    @Test("sem marcação de horário, a agenda não entra no pedido")
    func plainReplyDoesNotCarryTheAgenda() async throws {
        let banco = try SyncDatabase.temporary()
        try Fixture.escreveMensagem(in: banco.pool, id: "m1")
        try Fixture.escreveTriagem(in: banco.pool, id: "m1", triage: pedeResposta)
        let motor = EspiaoDeRascunho(resposta: "Fechado.")
        let fila = coordinator(
            database: banco, assistant: motor, settingsStore: try settings(),
            agenda: []
        )
        #expect(await fila.processPending() == 1)
        #expect(motor.ultimoTexto.isEmpty)
    }

    // MARK: - Golden do pedido

    @Test("golden: as folgas entram em português, com dia, data e hora")
    func agendaSeedGolden() {
        // 15/09/2026 é uma terça-feira.
        let terca = Date(timeIntervalSince1970: 1_788_861_600)
        let folgas: [FreeSlots.Slot] = [
            (day: 0, start: 900, end: 1020),
            (day: 1, start: 540, end: 660),
        ]
        #expect(
            ReadyDraftPrompt.agendaSeed(slots: folgas, now: terca)
                == """
                Minha disponibilidade nos próximos dias: terça 8/9 15h–17h; \
                quarta 9/9 9h–11h. Proponha um destes horários; não invente \
                outro nem prometa nada fora desta lista.
                """
        )
    }

    @Test("golden: sem folga nenhuma, o pedido não promete horário")
    func emptyAgendaSeedGolden() {
        #expect(
            ReadyDraftPrompt.agendaSeed(slots: [], now: Self.agora)
                == """
                Não tenho horário livre no expediente dos próximos dias. \
                Não proponha horário nenhum; peça alternativas.
                """
        )
    }
}

/// Um motor de texto que só devolve o que mandaram — e guarda o que recebeu.
final class EspiaoDeRascunho: TextAssisting, @unchecked Sendable {
    private let trava = NSLock()
    private var modelo = "espiao/rascunho-v1"
    var modelVersion: String { trava.withLock { modelo } }
    var versao: String {
        get { trava.withLock { modelo } }
        set { trava.withLock { modelo = newValue } }
    }
    private var texto: String
    private var chamadas = 0
    private var recebido = ""
    private var acoes: [WritingAction] = []

    init(resposta: String) { texto = resposta }

    var resposta: String {
        get { trava.withLock { texto } }
        set { trava.withLock { texto = newValue } }
    }
    var calls: Int { trava.withLock { chamadas } }
    var ultimoTexto: String { trava.withLock { recebido } }
    var acoesPedidas: [WritingAction] { trava.withLock { acoes } }

    func availability() async -> AppleIntelligenceAvailability { .available }

    func answer(
        question: String, in conversation: AssistantConversationSnapshot
    ) async throws -> String {
        trava.withLock { chamadas += 1 }
        return resposta
    }

    func transform(
        _ text: String, using action: WritingAction, context: AssistantMailContext?
    ) async throws -> String {
        trava.withLock {
            chamadas += 1
            recebido = text
            acoes.append(action)
        }
        return resposta
    }
}

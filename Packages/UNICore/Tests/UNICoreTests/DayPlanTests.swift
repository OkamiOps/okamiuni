import Foundation
import Testing

@testable import UNICore

/// O dia do dono, como o desenho 08 o escreve.
///
/// A fixture é a caixa dele em 3 de setembro de 2026: os sete emails que
/// motivaram o redesenho. Cada asserção aqui é uma frase do mockup — se o
/// `DayPlan` deixar de produzi-la, a tela deixa de ser a aprovada.
@Suite("DayPlan · o dia do dono")
struct DayPlanTests {

    // MARK: - Relógio

    /// Quinta, 3 de setembro de 2026, 10:00. Construída pelo calendário da
    /// máquina para o teste não depender do fuso de quem roda.
    static let agora: Date = {
        var partes = DateComponents()
        partes.year = 2026
        partes.month = 9
        partes.day = 3
        partes.hour = 10
        return Calendar.current.date(from: partes)!
    }()
    static let agoraMinuto = 600

    private var agora: Date { Self.agora }
    private var agoraMinuto: Int { Self.agoraMinuto }

    // MARK: - Os sete emails

    private func data(diasAtras: Int, hora: Int = 14, minuto: Int = 12) -> Date {
        let calendario = Calendar.current
        let dia = calendario.date(byAdding: .day, value: -diasAtras, to: Self.agora)!
        return calendario.date(bySettingHour: hora, minute: minuto, second: 0, of: dia)!
    }

    private func hoje(hora: Int, minuto: Int = 0) -> Date {
        Calendar.current.date(
            bySettingHour: hora, minute: minuto, second: 0, of: Self.agora
        )!
    }

    private func email(
        id: String,
        conta: String,
        de: Contact,
        recebido: Date,
        assunto: String,
        trecho: String,
        corpo: [String],
        lido: Bool = true,
        resumo: String? = nil,
        triagem: MessageTriage? = nil,
        marcas: BulkMailMarks = []
    ) -> Message {
        Message(
            id: id, accountID: conta, from: de, receivedAt: recebido,
            subject: assunto, snippet: trecho, body: corpo,
            tags: [], bucket: .today, isRead: lido,
            summary: resumo, detectedEvent: nil,
            triage: triagem, bulkMarks: marcas
        )
    }

    /// Jack Whitmore: pergunta literal, sete dias esperando, rascunho curto.
    private var jack: Message {
        email(
            id: "jack", conta: "okamiops",
            de: Contact(name: "Jack Whitmore", address: "jack@whitmore.dev"),
            recebido: data(diasAtras: 7),
            assunto: "Okami Tally doesn't show up for \"tally\"",
            trecho: "I can't find Okami Tally when I search for \"tally\". "
                + "Does the page require a login?",
            corpo: [
                "Hi Marcos,",
                "I can't find Okami Tally when I search for \"tally\". "
                    + "Does the page require a login?",
                "Thanks, Jack",
            ],
            resumo: "Não encontra o Okami Tally e pergunta se a página exige login.",
            triagem: MessageTriage(needsReply: true, intent: .request, urgency: .normal)
        )
    }

    /// Jayden Sutherland: pedido de disponibilidade, com prazo hoje às 18h.
    private var jayden: Message {
        email(
            id: "jayden", conta: "gmail",
            de: Contact(name: "Jayden Sutherland", address: "jayden@consult.example"),
            recebido: data(diasAtras: 2),
            assunto: "Paid Consultation Opportunity: Endpoint Operating Systems",
            trecho: "Please share two windows that work for you this week.",
            corpo: ["Please share two windows that work for you this week."],
            resumo: "Pede dois horários seus para uma consultoria paga.",
            triagem: MessageTriage(
                needsReply: true, intent: .scheduling, urgency: .high,
                deadline: DetectedDeadline(
                    date: hoje(hora: 18), evidence: "confirmar até hoje às 18h"
                )
            )
        )
    }

    /// Cats9th: pedido sem prazo, sem rascunho pronto.
    private var cats9th: Message {
        email(
            id: "cats9th", conta: "gmail",
            de: Contact(name: "Cats9th", address: "editor@cats9th.example"),
            recebido: data(diasAtras: 5),
            assunto: "Re: Check out your chapter page and personal bio",
            trecho: "Atualize seu perfil quando puder.",
            corpo: ["Atualize seu perfil quando puder."],
            resumo: "Pede para atualizar seu perfil no site deles.",
            triagem: MessageTriage(needsReply: true, intent: .request, urgency: .low)
        )
    }

    /// Abacus AI: prazo no sábado, disparo, e a pessoa nunca abriu.
    private var abacus: Message {
        email(
            id: "abacus", conta: "gmail",
            de: Contact(name: "Abacus AI", address: "no-reply@abacus.ai"),
            recebido: hoje(hora: 9, minuto: 54),
            assunto: "Erinnerung: Ihre 6,000 Bonus-Credits laufen in wenigen Tagen ab",
            trecho: "Ihre Bonus-Credits laufen ab.",
            corpo: ["Ihre Bonus-Credits laufen ab."],
            lido: false,
            triagem: MessageTriage(
                needsReply: true, intent: .transactional, urgency: .normal,
                deadline: DetectedDeadline(
                    date: data(diasAtras: -2, hora: 23, minuto: 59),
                    evidence: "6.000 créditos expiram sábado"
                )
            ),
            marcas: [.listUnsubscribe]
        )
    }

    /// Maria Exemplo: lead do formulário do site, com rascunho pronto.
    private var maria: Message {
        email(
            id: "maria", conta: "vantion",
            de: Contact(name: "Maria Exemplo", address: "maria@exemplo.com.br"),
            recebido: data(diasAtras: 1, hora: 16, minuto: 3),
            assunto: "Orçamento de identidade visual",
            trecho: "Gostaria de um orçamento de identidade visual.",
            corpo: ["Gostaria de um orçamento de identidade visual."],
            lido: false,
            resumo: "Pediu orçamento de identidade visual pelo formulário do site.",
            triagem: MessageTriage(needsReply: true, intent: .lead, urgency: .high)
        )
    }

    /// Carol da Zoho: a análise disse lead, o cabeçalho diz campanha.
    private var carol: Message {
        email(
            id: "carol", conta: "gmail",
            de: Contact(name: "Carol da Zoho", address: "carol@campanhas.zoho.example"),
            recebido: data(diasAtras: 1, hora: 11),
            assunto: "Zoho One: 30% off para novas equipes",
            trecho: "Aproveite a promoção.",
            corpo: ["Aproveite a promoção."],
            lido: false,
            triagem: MessageTriage(needsReply: true, intent: .lead, urgency: .normal),
            marcas: [.listUnsubscribe]
        )
    }

    /// Welcome to Resend: disparo, e só.
    private var resend: Message {
        email(
            id: "resend", conta: "gmail",
            de: Contact(name: "Resend", address: "no-reply@resend.example"),
            recebido: data(diasAtras: 3, hora: 8),
            assunto: "Welcome to Resend",
            trecho: "Obrigado por criar sua conta.",
            corpo: ["Obrigado por criar sua conta."],
            lido: false,
            triagem: MessageTriage(needsReply: true, intent: .newsletter, urgency: .low),
            marcas: [.listUnsubscribe]
        )
    }

    private func focus(_ mensagens: [Message]? = nil) -> DashboardFocus {
        let lista = mensagens ?? [jack, jayden, cats9th, abacus, maria, carol, resend]
        return DashboardFocus(
            mail: lista.map {
                DashboardFocus.MailItem(message: $0, reason: reason(for: $0))
            },
            meetings: [], pending: [],
            omittedMailCount: 0, omittedMeetingCount: 0,
            nextUpLabel: "Aitherion Labs",
            discardedMailCount: 233
        )
    }

    /// A etiqueta que o `DashboardFocus` daria — o `DayPlan` não depende dela,
    /// mas a fixture precisa ser honesta.
    private func reason(for message: Message) -> DashboardFocus.Reason {
        if message.effectiveBulkMarks.isBulk { return .broadcast }
        if message.triage?.intent == .lead { return .lead }
        if message.triage?.deadline != nil { return .deadline }
        return .needsReply
    }

    // MARK: - Rascunhos

    private func draft(_ message: Message, _ texto: String) -> ReadyDraft {
        ReadyDraft(
            messageID: message.id, text: texto,
            contentHash: ReadyDraft.contentHash(for: message),
            modelVersion: "foundation-1", usedAgenda: message.triage?.intent == .scheduling
        )
    }

    private var rascunhos: [String: ReadyDraft] {
        let jack = jack
        let jayden = jayden
        let maria = maria
        return [
            jack.id: draft(
                jack,
                "Oi Jack,\n\nSim — hoje a página exige login, por isso a busca não acha. "
                    + "Libero a pública até sexta.\n\nAbraço,\nMarcos"
            ),
            jayden.id: draft(
                jayden,
                "Oi Jayden,\n\nTerça 9/9 ou quinta 11/9, das 15h às 17h.\n\nAbraço,\nMarcos"
            ),
            maria.id: draft(
                maria,
                "Oi Maria,\n\nObrigado pelo contato — posso te ligar amanhã às 10h?"
                    + "\n\nAbraço,\nMarcos"
            ),
        ]
    }

    // MARK: - Agenda do dia

    /// A agenda do 08: Odette, Aitherion e o almoço. A primeira folga de vinte
    /// minutos depois das 10h começa às 13h.
    private var agenda: [AgendaItem] {
        [
            AgendaItem(
                id: "odette", title: "Termin de Odette",
                startMinute: 570, endMinute: 600, accountID: "gmail"
            ),
            AgendaItem(
                id: "aitherion", title: "Aitherion Labs · Estratégia Econômica",
                startMinute: 600, endMinute: 720, accountID: "gmail"
            ),
            AgendaItem(
                id: "almoco", title: "Almoço",
                startMinute: 720, endMinute: 780, accountID: "gmail"
            ),
        ]
    }

    private func plano(
        filtro: DayPlan.Filter = .standard,
        regras: [SenderRule] = [],
        mensagens: [Message]? = nil,
        agenda: [AgendaItem]? = nil
    ) -> DayPlan {
        DayPlan.make(
            focus: focus(mensagens),
            drafts: rascunhos,
            rules: regras,
            agenda: agenda ?? self.agenda,
            filter: filtro,
            now: Self.agora,
            nowMinute: Self.agoraMinuto
        )
    }

    // MARK: - O herói

    @Test("o herói é o Jack, com a frase do mockup")
    func heroISJack() {
        let plano = plano()
        #expect(plano.hero?.messageID == "jack")
        #expect(
            plano.hero?.sentence
                == "Jack espera há 7 dias, e é sim ou não. A resposta já está escrita."
        )
        #expect(plano.hero?.hasReadyDraft == true)
    }

    @Test("rascunho longo perde o \"é sim ou não\"")
    func longDraftDropsYesOrNo() {
        let jack = jack
        let longo = ReadyDraft(
            messageID: jack.id,
            text: "Oi Jack,\n\n" + String(repeating: "Explico com calma. ", count: 12)
                + "\n\nAbraço,\nMarcos",
            contentHash: ReadyDraft.contentHash(for: jack),
            modelVersion: "foundation-1"
        )
        var comLongo = rascunhos
        comLongo[jack.id] = longo
        let plano = DayPlan.make(
            focus: focus(), drafts: comLongo, rules: [], agenda: agenda,
            filter: .standard, now: agora, nowMinute: agoraMinuto
        )
        #expect(plano.hero?.sentence == "Jack espera há 7 dias. A resposta já está escrita.")
    }

    @Test("sem rascunho nenhum, o herói é o mais antigo e não promete resposta")
    func heroWithoutDraft() {
        let plano = DayPlan.make(
            focus: focus(), drafts: [:], rules: [], agenda: agenda,
            filter: .standard, now: agora, nowMinute: agoraMinuto
        )
        #expect(plano.hero?.messageID == "jack")
        #expect(plano.hero?.sentence == "Jack espera há 7 dias.")
        #expect(plano.hero?.hasReadyDraft == false)
    }

    @Test("ninguém esperando, nenhum herói")
    func heroNilWhenNobodyWaits() {
        let plano = plano(mensagens: [carol, resend])
        #expect(plano.hero == nil)
    }

    // MARK: - O porquê

    @Test("o porquê do Jack é a pergunta literal, entre aspas")
    func whyIsTheLiteralQuestion() {
        let linha = row("jack", in: plano())
        #expect(linha?.why == "\u{201C}Does the page require a login?\u{201D}")
    }

    @Test("sem pergunta no texto, o porquê é o pedido resumido")
    func whyFallsBackToSummary() {
        let linha = row("cats9th", in: plano())
        #expect(linha?.why == "Pede para atualizar seu perfil no site deles.")
    }

    @Test("sem pergunta e sem resumo, o porquê é o prazo")
    func whyFallsBackToDeadline() {
        let linha = row("abacus", in: plano())
        #expect(linha?.why == "6.000 créditos expiram sábado.")
    }

    @Test("o porquê cabe numa linha")
    func whyFitsOneLine() {
        let falante = email(
            id: "cats9th", conta: "gmail",
            de: Contact(name: "Cats9th", address: "editor@cats9th.example"),
            recebido: data(diasAtras: 5),
            assunto: "Re: Check out your chapter page and personal bio",
            trecho: "Atualize seu perfil quando puder.",
            corpo: ["Atualize seu perfil quando puder."],
            resumo: String(repeating: "Pede para atualizar o perfil no site deles. ", count: 6),
            triagem: MessageTriage(needsReply: true, intent: .request, urgency: .low)
        )
        let plano = plano(mensagens: [jack, jayden, falante, abacus, maria])
        for secao in plano.sections {
            for linha in secao.rows {
                #expect(linha.why.count <= DayPlan.whyLimit)
            }
        }
        #expect(row("cats9th", in: plano)?.why.hasSuffix("…") == true)
    }

    // MARK: - As propostas

    @Test("Jayden vira enviar o rascunho, com a primeira frase entre aspas")
    func jaydenBecomesSendDraft() {
        guard case let .sendDraft(id, preview) = row("jayden", in: plano())?.proposal else {
            Issue.record("Jayden devia propor enviar o rascunho")
            return
        }
        #expect(id == "jayden")
        #expect(preview == "\u{201C}Terça 9/9 ou quinta 11/9, das 15h às 17h.\u{201D}")
        #expect(preview.count <= DayPlan.previewLimit)
    }

    @Test("rascunho de outra versão da mensagem não vale")
    func staleDraftIsIgnored() {
        let jack = jack
        var velhos = rascunhos
        velhos[jack.id] = ReadyDraft(
            messageID: jack.id, text: "Resposta de ontem.",
            contentHash: "outro-hash", modelVersion: "foundation-1"
        )
        let plano = DayPlan.make(
            focus: focus(), drafts: velhos, rules: [], agenda: agenda,
            filter: .standard, now: agora, nowMinute: agoraMinuto
        )
        if case .sendDraft = row("jack", in: plano)?.proposal {
            Issue.record("um rascunho de outro texto não pode virar \"Enviar\"")
        }
    }

    /// **A proposta não marca hora.** O app não tem adiamento com volta: nada
    /// devolve uma mensagem para Hoje numa data marcada. Prometer "sexta de
    /// manhã" numa tela que só move para a caixa Depois seria a IA prometendo
    /// um comportamento que o app não tem (I1 da revisão final).
    @Test("Cats9th vira deixar para depois, sem marcar hora nenhuma")
    func cats9thBecomesLater() {
        guard case let .later(id, porque) = row("cats9th", in: plano())?.proposal else {
            Issue.record("Cats9th devia propor deixar para depois")
            return
        }
        #expect(id == "cats9th")
        #expect(porque == "Sem prazo, e exige a sua atenção. Tirar de hoje e deixar para depois?")
        for dia in ["segunda", "terça", "quarta", "quinta", "sexta", "sábado", "domingo"] {
            #expect(!porque.contains(dia), "a frase promete \(dia), e nada volta nesse dia")
        }
        #expect(!porque.contains("manhã"), "a frase promete uma hora que o app não cumpre")
    }

    @Test("Abacus vira arquivar e aprender")
    func abacusBecomesArchiveAndLearn() {
        guard case let .archiveAndLearn(id, porque) =
            row("abacus", in: plano())?.proposal
        else {
            Issue.record("Abacus devia propor arquivar e aprender")
            return
        }
        #expect(id == "abacus")
        #expect(porque == "Você nunca abriu um email deles — arquivar e não trazer mais?")
    }

    @Test("remetente que a pessoa já abriu não vira arquivar e aprender")
    func openedSenderKeeps() {
        let lido = email(
            id: "abacus", conta: "gmail",
            de: Contact(name: "Abacus AI", address: "no-reply@abacus.ai"),
            recebido: hoje(hora: 9, minuto: 54),
            assunto: "Erinnerung", trecho: "Credits", corpo: ["Credits"],
            lido: true,
            triagem: abacus.triage,
            marcas: [.listUnsubscribe]
        )
        let plano = plano(mensagens: [jack, lido])
        if case .archiveAndLearn = row("abacus", in: plano)?.proposal {
            Issue.record("ela já abriu um email deles — não dá para dizer que nunca abriu")
        }
    }

    // MARK: - Seções

    @Test("as três seções do mockup, com as linhas do mockup")
    func sectionsMatchTheMockup() {
        let plano = plano()
        #expect(plano.sections.map(\.kind) == [.waitingOnYou, .due, .lead])
        #expect(plano.sections[0].rows.map(\.id) == ["jack", "jayden", "cats9th"])
        #expect(plano.sections[1].rows.map(\.id) == ["abacus"])
        #expect(plano.sections[2].rows.map(\.id) == ["maria"])
    }

    // MARK: - Tirei da lista

    @Test("Carol e Resend saem da lista, com porquês diferentes")
    func removedExplainsItself() {
        let plano = plano()
        let porID = Dictionary(
            uniqueKeysWithValues: plano.removed.map { ($0.messageID, $0) }
        )
        #expect(porID["carol"]?.why == "campanha, não lead")
        #expect(porID["resend"]?.why == "disparo")
        #expect(porID["carol"]?.subject == "Zoho One: 30% off para novas equipes")
        #expect(plano.sections.flatMap(\.rows).contains { $0.id == "carol" } == false)
    }

    @Test("a regra da pessoa tira o remetente e diz que foi ela")
    func senderRuleRemovesAndExplains() {
        let regra = SenderRule(
            address: "EDITOR@Cats9th.example", createdAt: agora
        )
        let plano = plano(regras: [regra])
        #expect(plano.removed.contains { $0.messageID == "cats9th" })
        #expect(
            plano.removed.first { $0.messageID == "cats9th" }?.why
                == "regra sua: nunca é prioridade"
        )
        #expect(plano.sections[0].rows.map(\.id) == ["jack", "jayden"])
        // A contagem é do que chegou: a regra tira da lista, não da conta.
        #expect(plano.counts[.people] == 3)
    }

    // MARK: - Contagem e filtro

    @Test("a contagem do filtro bate com a fixture")
    func countsMatchTheFixture() {
        let plano = plano()
        #expect(plano.counts[.people] == 3)
        #expect(plano.counts[.deadlines] == 1)
        #expect(plano.counts[.leads] == 1)
        #expect(plano.counts[.broadcasts] == 2)
        #expect(plano.counts[.newsletters] == 233)
    }

    @Test("desligar \"gente\" esvazia a seção sem mexer na contagem")
    func filterEmptiesSectionButNotCounts() {
        let plano = plano(filtro: DayPlan.Filter(on: [.deadlines, .leads]))
        #expect(plano.sections.contains { $0.kind == .waitingOnYou } == false)
        #expect(plano.hero == nil)
        #expect(plano.counts[.people] == 3)
    }

    @Test("filtrar por conta deixa só as linhas daquela conta")
    func filterByAccount() {
        let plano = plano(
            filtro: DayPlan.Filter(on: [.people, .deadlines, .leads], accounts: ["vantion"])
        )
        #expect(plano.sections.flatMap(\.rows).map(\.id) == ["maria"])
    }

    // MARK: - Bloco de resposta

    @Test("o bloco cai na primeira folga e junta as três respostas prontas")
    func replyBlockLandsOnTheFirstFreeSlot() {
        let plano = plano()
        #expect(plano.replyBlock?.day == 0)
        #expect(plano.replyBlock?.startMinute == 780)
        #expect(plano.replyBlock?.minutes == 20)
        #expect(plano.replyBlock?.messageIDs.sorted() == ["jack", "jayden", "maria"])
    }

    @Test("o bloco termina antes do prazo de hoje, ou não existe")
    func replyBlockRespectsTodaysDeadline() {
        let apertado = [
            AgendaItem(
                id: "manha", title: "Bloco cheio",
                startMinute: 540, endMinute: 700, accountID: "gmail"
            )
        ]
        let cedo = email(
            id: "jayden", conta: "gmail",
            de: Contact(name: "Jayden Sutherland", address: "jayden@consult.example"),
            recebido: data(diasAtras: 2),
            assunto: "Paid Consultation Opportunity: Endpoint Operating Systems",
            trecho: "Please share two windows that work for you this week.",
            corpo: ["Please share two windows that work for you this week."],
            resumo: "Pede dois horários seus para uma consultoria paga.",
            triagem: MessageTriage(
                needsReply: true, intent: .scheduling, urgency: .high,
                deadline: DetectedDeadline(
                    date: hoje(hora: 11, minuto: 50), evidence: "hoje às 11h50"
                )
            )
        )
        // A folga começa às 11:40 e o prazo é 11:50: vinte minutos não cabem.
        #expect(plano(mensagens: [jack, cedo], agenda: apertado).replyBlock == nil)

        let folgado = [
            AgendaItem(
                id: "manha", title: "Bloco cheio",
                startMinute: 540, endMinute: 690, accountID: "gmail"
            )
        ]
        let bloco = plano(mensagens: [jack, cedo], agenda: folgado).replyBlock
        #expect(bloco?.startMinute == 690)
    }

    @Test("sem folga nenhuma, não há bloco")
    func replyBlockNilWithoutSlots() {
        let cheio = [
            AgendaItem(
                id: "tudo", title: "Dia inteiro",
                startMinute: 540, endMinute: 1080, accountID: "gmail"
            )
        ]
        #expect(plano(agenda: cheio).replyBlock == nil)
    }

    // MARK: - Utilidades

    private func row(_ id: String, in plan: DayPlan) -> DayPlan.Row? {
        plan.sections.flatMap(\.rows).first { $0.id == id }
    }
}

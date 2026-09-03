import Foundation
import Testing
@testable import UNICore

/// A coluna de prioridades com os sete e-mails da captura do dono.
///
/// A queixa era literal: "eu não sei qual a caixa, não tem prioridade direito".
/// Sete linhas com a mesma etiqueta `PRECISA RESPOSTA`, ordenadas só por data,
/// três delas disparo em massa. Estes testes são a régua do conserto.
@Suite("Triagem de disparo em massa no dashboard")
struct DashboardTriagemDeDisparoTests {

    private let agora = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: A barreira determinística

    @Test("cada cabeçalho de disparo derruba needsReply, mesmo a análise afirmando")
    func cabecalhosDerrubamNeedsReply() {
        let afirmativa = MessageTriage(needsReply: true, intent: .request, urgency: .high)
        let marcas: [BulkMailMarks] = [
            .listUnsubscribe, .listID, .precedence,
            .autoSubmitted, .autoResponseSuppress, .noReplySender,
        ]
        for marca in marcas {
            let barrada = afirmativa.barred(byBulk: marca)
            #expect(!barrada.needsReply, "\(marca.rawValue) devia derrubar needsReply")
            // O resto da análise sobrevive: a barreira nega **uma** afirmação,
            // não apaga o que o modelo leu.
            #expect(barrada.intent == .request)
            #expect(barrada.urgency == .high)
        }
        #expect(afirmativa.barred(byBulk: []).needsReply)
    }

    @Test("no-reply@ não é prioridade nem com a análise pedindo resposta")
    func noReplyNaoEPrioridade() {
        let disparo = mail(
            id: "disparo",
            from: Contact(name: "Upwork", address: "do-not-reply@upwork.com"),
            triage: MessageTriage(needsReply: true, intent: .request, urgency: .high)
        )
        let snap = DashboardFocus.snapshot(
            messages: [disparo], agenda: [], pending: [], nowMinute: 720, now: agora
        )
        #expect(snap.mail.first?.reason != .needsReply)
    }

    @Test("email pessoal com pergunta continua prioridade")
    func pessoalContinuaPrioridade() {
        let pessoa = mail(
            id: "jack",
            from: Contact(name: "Jack Whitmore", address: "jack@whitmore.co"),
            triage: MessageTriage(needsReply: true, intent: .request, urgency: .normal)
        )
        let snap = DashboardFocus.snapshot(
            messages: [pessoa], agenda: [], pending: [], nowMinute: 720, now: agora
        )
        #expect(snap.mail.map(\.id) == ["jack"])
        #expect(snap.mail.first?.reason == .needsReply)
    }

    // MARK: A hierarquia, com os sete da captura

    @Test("gente acima de máquina, com etiquetas diferentes")
    func genteAcimaDeMaquina() {
        let snap = DashboardFocus.snapshot(
            messages: Self.seteDaCaptura(agora: agora),
            agenda: [], pending: [], nowMinute: 720, now: agora
        )
        let ordem = snap.mail.map(\.id)
        // Os três disparos ficam **abaixo** de todo mundo que é gente.
        let disparos = ["resend", "zoho", "upwork"]
        let pessoas = ["jack", "jayden", "vantion", "cats9th"]
        for disparo in disparos {
            guard let posicaoDoDisparo = ordem.firstIndex(of: disparo) else { continue }
            for pessoa in pessoas {
                guard let posicaoDaPessoa = ordem.firstIndex(of: pessoa) else { continue }
                #expect(
                    posicaoDaPessoa < posicaoDoDisparo,
                    "\(pessoa) tem de ficar acima de \(disparo)"
                )
            }
        }
        // E nenhum disparo pode reivindicar resposta.
        for item in snap.mail where disparos.contains(item.id) {
            #expect(item.reason != .needsReply)
            #expect(item.reason != .lead)
            #expect(item.reason != .deadline)
        }
    }

    @Test("sete etiquetas iguais era o defeito: a coluna passa a ter mais de uma")
    func etiquetasVariam() {
        let snap = DashboardFocus.snapshot(
            messages: Self.seteDaCaptura(agora: agora),
            agenda: [], pending: [], nowMinute: 720, now: agora
        )
        let etiquetas = Set(snap.mail.map(\.reason.label))
        #expect(etiquetas.count >= 3, "etiquetas vistas: \(etiquetas)")
    }

    @Test("o disparo que aparece diz que é disparo")
    func disparoDizQueEDisparo() {
        let upwork = mail(
            id: "upwork",
            from: Contact(name: "Upwork", address: "do-not-reply@upwork.com"),
            isRead: false,
            triage: MessageTriage(needsReply: true, intent: .request, urgency: .normal)
        )
        let snap = DashboardFocus.snapshot(
            messages: [upwork], agenda: [], pending: [], nowMinute: 720, now: agora
        )
        #expect(snap.mail.first?.reason == .broadcast)
        #expect(snap.mail.first?.reason.label == "Disparo")
    }

    // MARK: O que já foi respondido

    @Test("mensagem já respondida sai do topo")
    func respondidaSaiDoTopo() {
        let pergunta = Message(
            id: "pergunta", accountID: "a",
            from: Contact(name: "Jayden", address: "jayden@sutherland.co"),
            receivedAt: agora.addingTimeInterval(-7_200),
            subject: "Podemos fechar hoje?", snippet: "", body: [],
            tags: [], bucket: .today, isRead: true,
            summary: nil, detectedEvent: nil,
            triage: MessageTriage(needsReply: true, intent: .request, urgency: .high),
            rfcMessageID: "pergunta@sutherland.co", threadKey: "t1"
        )
        let outra = mail(
            id: "outra",
            from: Contact(name: "Cats9th", address: "ana@cats9th.com"),
            triage: MessageTriage(needsReply: true, intent: .request, urgency: .normal)
        )
        let minhaResposta = Message(
            id: "resposta", accountID: "a",
            from: Contact(name: "Marcos", address: "marcos@okamiops.com"),
            receivedAt: agora.addingTimeInterval(-600),
            subject: "Re: Podemos fechar hoje?", snippet: "", body: [],
            tags: [], bucket: .sent, isRead: true,
            summary: nil, detectedEvent: nil,
            references: ["pergunta@sutherland.co"], threadKey: "t1"
        )
        let snap = DashboardFocus.snapshot(
            messages: [pergunta, outra, minhaResposta],
            agenda: [], pending: [], nowMinute: 720, now: agora
        )
        #expect(!snap.mail.map(\.id).contains("pergunta"))
        #expect(snap.mail.map(\.id) == ["outra"])
    }

    @Test("resposta mais antiga que a pergunta não a resolve")
    func respostaAntigaNaoResolve() {
        let pergunta = Message(
            id: "pergunta", accountID: "a",
            from: Contact(name: "Jayden", address: "jayden@sutherland.co"),
            receivedAt: agora.addingTimeInterval(-600),
            subject: "E agora?", snippet: "", body: [],
            tags: [], bucket: .today, isRead: true,
            summary: nil, detectedEvent: nil,
            triage: MessageTriage(needsReply: true, intent: .request, urgency: .high),
            rfcMessageID: "nova@sutherland.co", threadKey: "t1"
        )
        let respostaVelha = Message(
            id: "velha", accountID: "a",
            from: Contact(name: "Marcos", address: "marcos@okamiops.com"),
            receivedAt: agora.addingTimeInterval(-7_200),
            subject: "Re: antes", snippet: "", body: [],
            tags: [], bucket: .sent, isRead: true,
            summary: nil, detectedEvent: nil,
            references: ["antiga@sutherland.co"], threadKey: "t1"
        )
        let snap = DashboardFocus.snapshot(
            messages: [pergunta, respostaVelha],
            agenda: [], pending: [], nowMinute: 720, now: agora
        )
        #expect(snap.mail.map(\.id) == ["pergunta"])
    }

    // MARK: As fixtures da captura

    /// Os sete e-mails da captura do dono, com os cabeçalhos que eles têm de
    /// verdade. Três são disparo; quatro são gente.
    static func seteDaCaptura(agora: Date) -> [Message] {
        func msg(
            _ id: String, _ nome: String, _ endereco: String, _ assunto: String,
            marcas: BulkMailMarks = [], needsReply: Bool = true,
            intent: MessageTriage.Intent = .request, minutos: Double,
            prazo: DetectedDeadline? = nil
        ) -> Message {
            Message(
                id: id, accountID: "a",
                from: Contact(name: nome, address: endereco),
                receivedAt: agora.addingTimeInterval(-minutos * 60),
                subject: assunto, snippet: assunto, body: [],
                tags: [], bucket: .today, isRead: false,
                summary: nil, detectedEvent: nil,
                triage: MessageTriage(
                    needsReply: needsReply, intent: intent, urgency: .normal, deadline: prazo
                ),
                bulkMarks: marcas
            )
        }
        return [
            msg(
                "resend", "Resend", "onboarding@resend.dev", "Welcome to Resend!",
                marcas: [.listUnsubscribe], intent: .transactional, minutos: 30
            ),
            msg(
                "zoho", "Zoho", "marketing@zoho.com",
                "Quando surge uma nova necessidade, onde você procura a solução?",
                marcas: [.listUnsubscribe, .listID, .precedence],
                intent: .newsletter, minutos: 60
            ),
            msg(
                "upwork", "Upwork", "do-not-reply@upwork.com",
                "Invitation to Interview for: Software Testing",
                marcas: [.noReplySender, .autoSubmitted], minutos: 90
            ),
            msg("cats9th", "Cats9th", "contato@cats9th.com", "Proposta de parceria", minutos: 240),
            msg(
                "jack", "Jack Whitmore", "jack@whitmore.co", "Pode confirmar sexta?",
                minutos: 300,
                prazo: DetectedDeadline(
                    date: agora.addingTimeInterval(20 * 3_600), evidence: "sexta"
                )
            ),
            msg(
                "jayden", "Jayden Sutherland", "jayden@sutherland.co",
                "Retomando nosso assunto", minutos: 360
            ),
            msg(
                "vantion", "Formulário Vantion", "site@vantion.com.br",
                "Novo contato pelo formulário", intent: .lead, minutos: 420
            ),
        ]
    }

    private func mail(
        id: String,
        from: Contact,
        bucket: TriageBucket = .today,
        isRead: Bool = false,
        triage: MessageTriage? = nil,
        bulkMarks: BulkMailMarks = []
    ) -> Message {
        Message(
            id: id, accountID: "a", from: from, receivedAt: Fixtures.today,
            subject: id, snippet: id, body: [],
            tags: [], bucket: bucket, isRead: isRead,
            summary: nil, detectedEvent: nil, triage: triage,
            bulkMarks: bulkMarks
        )
    }
}

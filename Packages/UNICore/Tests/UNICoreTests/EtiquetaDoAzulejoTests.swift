import Foundation
import Testing

@testable import UNICore

/// A etiqueta do azulejo do painel 11 — o defeito 6 da captura do dono: seis
/// azulejos dizendo "LEAD NOVO" e uma newsletter dizendo "ESPERANDO".
@Suite("Etiqueta do azulejo")
struct EtiquetaDoAzulejoTests {

    /// Quinta, 3 de setembro de 2026, 10:00.
    private static let hoje: Date = {
        var partes = DateComponents()
        partes.year = 2026; partes.month = 9; partes.day = 3; partes.hour = 10
        return Calendar.current.date(from: partes)!
    }()

    private static let minhasContas: Set<String> = [
        "marcos@okamiops.com", "contato@vantion.com.br", "msant262@gmail.com",
    ]

    private func mensagem(
        id: String, de: Contact, assunto: String,
        triagem: MessageTriage?, marcas: BulkMailMarks = [],
        corpo: [String] = ["Um texto qualquer."]
    ) -> Message {
        Message(
            id: id, accountID: "gmail", from: de, receivedAt: Self.hoje,
            subject: assunto, snippet: corpo.first ?? "", body: corpo,
            tags: [], bucket: .today, isRead: false,
            summary: nil, detectedEvent: nil,
            triage: triagem, bulkMarks: marcas
        )
    }

    private func decidir(
        _ message: Message, enviei: Bool = false
    ) -> EtiquetaDoAzulejo? {
        EtiquetaDoAzulejo.decidir(
            message: message,
            marks: message.effectiveBulkMarks,
            triage: message.triage,
            hasSentInThread: enviei,
            myAddresses: Self.minhasContas,
            today: Self.hoje
        )
    }

    // MARK: - As cinco mensagens da captura

    @Test("Cats9th tem \"Re:\" no assunto: é conversa em andamento, não lead")
    func aReplyIsNeverANewLead() {
        let cats = mensagem(
            id: "cats9th",
            de: Contact(name: "Cats9th", address: "editor@cats9th.example"),
            assunto: "Re: Check out your chapter page and personal bio",
            triagem: MessageTriage(needsReply: true, intent: .lead, urgency: .low)
        )
        #expect(decidir(cats) == .esperando)
    }

    @Test("Jayden pede consultoria com prazo hoje: prazo hoje, nunca lead novo")
    func jaydenIsARequestWithATimeLimit() {
        let jayden = mensagem(
            id: "jayden",
            de: Contact(name: "Jayden Sutherland", address: "jayden@prosapient.example"),
            assunto: "Paid Consultation Opportunity: Endpoint Operating Systems",
            triagem: MessageTriage(
                needsReply: true, intent: .scheduling, urgency: .high,
                deadline: DetectedDeadline(
                    date: Self.hoje.addingTimeInterval(8 * 3_600),
                    evidence: "confirmar até hoje às 18h"
                )
            )
        )
        #expect(decidir(jayden) == .prazoHoje)

        // E sem o prazo, ele continua sendo um pedido de gente — "esperando".
        let semPrazo = mensagem(
            id: "jayden2",
            de: Contact(name: "Jayden Sutherland", address: "jayden@prosapient.example"),
            assunto: "Paid Consultation Opportunity",
            triagem: MessageTriage(needsReply: true, intent: .request, urgency: .high)
        )
        #expect(decidir(semPrazo) == .esperando)
    }

    @Test("máquina não vira azulejo: nem Resend, nem Zeno, nem newsletter")
    func machinesNeverGetATile() {
        let resend = mensagem(
            id: "resend",
            de: Contact(name: "Resend", address: "no-reply@resend.example"),
            assunto: "Welcome to Resend",
            triagem: MessageTriage(needsReply: true, intent: .newsletter, urgency: .low),
            marcas: [.listUnsubscribe]
        )
        #expect(decidir(resend) == nil, "a newsletter aparecia como ESPERANDO")

        // O disparo que o modelo chamou de lead: o cabeçalho desmente.
        let zeno = mensagem(
            id: "zeno",
            de: Contact(name: "Zeno", address: "hello@zeno.example"),
            assunto: "Conheça o Zeno",
            triagem: MessageTriage(needsReply: true, intent: .lead, urgency: .normal),
            marcas: [.listUnsubscribe]
        )
        #expect(decidir(zeno) == nil, "campanha não é lead novo")
    }

    @Test("o formulário de teste do próprio dono nunca é lead")
    func youAreNeverYourOwnLead() {
        let formulario = mensagem(
            id: "formulario",
            de: Contact(name: "Marcos", address: "marcos@okamiops.com"),
            assunto: "Novo contato pelo site",
            triagem: MessageTriage(needsReply: true, intent: .lead, urgency: .high)
        )
        #expect(decidir(formulario) == .esperando)
    }

    @Test("a Maria, que chegou pelo site e nunca falou comigo, é lead novo")
    func aStrangerAskingForWorkIsALead() {
        let maria = mensagem(
            id: "maria",
            de: Contact(name: "Maria Exemplo", address: "maria@exemplo.com.br"),
            assunto: "Orçamento de identidade visual",
            triagem: MessageTriage(needsReply: true, intent: .lead, urgency: .high)
        )
        #expect(decidir(maria) == .leadNovo)
        // E deixa de ser lead assim que eu respondo naquela conversa.
        #expect(decidir(maria, enviei: true) == .esperando)
    }

    // MARK: - As peças

    @Test(
        "o prefixo de resposta é reconhecido como os clientes o escrevem",
        arguments: [
            "Re: Orçamento", "RE: Orçamento", "res: Orçamento", "Fwd: Orçamento",
            "ENC: Orçamento", "Re: Re: Orçamento", "RE[2]: Orçamento",
            "Re: Fwd: Orçamento",
        ]
    )
    func replyPrefixesAreRecognized(assunto: String) {
        #expect(EtiquetaDoAzulejo.ehResposta(assunto: assunto))
    }

    @Test(
        "e uma palavra parecida não é prefixo nenhum",
        arguments: ["Resposta ao seu pedido", "Renovação do contrato", "Encontro de sexta"]
    )
    func lookalikesAreNotPrefixes(assunto: String) {
        #expect(!EtiquetaDoAzulejo.ehResposta(assunto: assunto))
    }

    /// O defeito 5: `marcos@okamiops.com` num segmento de 12 pt.
    @Test("o segmento do filtro escreve o nome da conta, não o email inteiro")
    func theAccountSegmentWritesAName() {
        // Com nome escolhido, é ele que vale.
        #expect(conta(displayName: "Okamiops", address: "marcos@okamiops.com")
            .shortName == "Okamiops")
        // Sem nome — e é assim que as contas de verdade nascem —, o domínio.
        #expect(conta(displayName: "marcos@okamiops.com", address: "marcos@okamiops.com")
            .shortName == "Okamiops")
        #expect(conta(displayName: "", address: "contato@vantion.com.br")
            .shortName == "Vantion")
        #expect(conta(displayName: "msant262@gmail.com", address: "msant262@gmail.com")
            .shortName == "Gmail")
    }

    private func conta(displayName: String, address: String) -> Account {
        Account(
            id: "x", address: address, displayName: displayName,
            provider: .imap, host: "h",
            tintLightHex: "#3D6FA5", tintDarkHex: "#6FA8DC"
        )
    }
}

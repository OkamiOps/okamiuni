import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
import UNISync
@testable import UNIShell

/// Os **quatro** emails das capturas do dono, como fixtures.
///
/// Não são exemplos inventados: são as mensagens que ele fotografou dizendo
/// "eu não sei se está fazendo alguma coisa… essa formatação, design, UX não
/// está boa". Cada uma cobra um defeito.
enum QuatroEmails {

    /// (a) Resend, em **HTML** — a casca de tabela do react-email, que era o
    /// que comia as fronteiras de bloco.
    static let resendHTML = """
        <html><body>
        <table width="100%" cellpadding="0" cellspacing="0"><tbody>
        <tr><td style="padding:24px">
          <p>Hey,</p>
          <p>My name is Zeno &mdash; I'm the founder and CEO of Resend.</p>
          <p>We started Resend because we wanted a better email API for developers.<br>
             A simple, fast, and elegant interface that just works.</p>
          <p>Here are 3 tips to get started.</p>
          <ol>
            <li><a href="https://resend.com/onboarding">Send your first email</a></li>
            <li><a href="https://resend.com/domains">Add your domain</a></li>
            <li><a href="https://resend.com/docs">Check the docs</a></li>
          </ol>
          <p>P.S.: Why did you sign up?</p>
        </td></tr>
        </tbody></table>
        </body></html>
        """

    /// (b) O formulário Vantion, com os dois ecos do assunto e o nome da
    /// empresa solto no fim.
    static let vantionHTML = """
        <div>Nova resposta</div>
        <div>Teste de configuração</div>
        <table>
          <tr><td>Nome</td><td>Maria Exemplo</td></tr>
          <tr><td>E-mail</td><td>maria@exemplo.com</td></tr>
          <tr><td>Mensagem</td><td>Gostaria de um orçamento para o projeto de identidade visual.</td></tr>
          <tr><td>Recebido em</td><td>25/08/2026 09:41</td></tr>
        </table>
        <div>Cartões Digitais Vantion</div>
        """
    static let vantionAssunto = "Nova resposta: Teste de configuração"

    /// (c) A proposta longa da proSapient — a que hoje é cortada pela fileira
    /// de botões, sem aviso nenhum.
    static let proposta = """
        Hi Marcos,

        Thank you for your interest in this project. We are working with a \
        client who is looking to speak with experts on digital business cards \
        and employee onboarding tooling in Brazil.

        The consultation would be a 60 minute call, scheduled at your \
        convenience, and we are able to offer a rate of USD 250 per hour for \
        your time. Payment is made within 30 days of the call.

        Before we can proceed, we need you to confirm three things: that you \
        are not currently under an NDA that would prevent this conversation, \
        that you will not disclose confidential information from any current \
        or former employer, and that you are available in the next two weeks.

        If you are happy to proceed, please reply to this email with your \
        availability and we will send over the compliance form.

        As a reminder, this is the topic of our consultation:
        """

    /// (d) A cadeia com histórico citado.
    static let cadeia = """
        Love the site!

        On Mon, Aug 25, 2026 at 9:41 AM Marina Álvares <marina@exemplo.com> wrote:
        \((1...38).map { "> Linha \($0) do histórico citado desta conversa longa." }
            .joined(separator: "\n"))
        """

    static func mensagem(
        id: String,
        assunto: String = "Assunto do email",
        corpo: [String] = [],
        html: String? = nil,
        resumo: String? = nil,
        triagem: MessageTriage? = nil
    ) -> Message {
        Message(
            id: id, accountID: "zoho",
            from: Contact(name: "Marina Álvares", address: "marina@exemplo.com"),
            receivedAt: Date(timeIntervalSince1970: 1_756_120_860),
            subject: assunto, snippet: "Trecho", body: corpo,
            tags: [], bucket: .today, isRead: false,
            summary: resumo, detectedEvent: nil, triage: triagem, bodyHTML: html
        )
    }
}

@Suite("A prévia rola, e diz que rola")
@MainActor
struct PreviaLegivelTests {

    private static let colunaDaPrevia = CGSize(width: 380, height: 300)

    private func corpoLongo() -> CorpoLegivel {
        CorpoLegivel.deTextoSimples(QuatroEmails.proposta)
    }

    private func corpoCurto() -> CorpoLegivel {
        CorpoLegivel.deTextoSimples("Oi, Marcos. Tudo certo por aqui.")
    }

    @Test("o corpo que não cabe avisa que tem mais abaixo")
    func avisoDeMaisAbaixo() throws {
        let tema = Theme.tinta
        let longo = try #require(
            Render.bitmap(
                CorpoRolavel(corpo: corpoLongo()).background(tema.paper.color),
                size: Self.colunaDaPrevia, theme: tema
            )
        )
        let curto = try #require(
            Render.bitmap(
                CorpoRolavel(corpo: corpoCurto()).background(tema.paper.color),
                size: Self.colunaDaPrevia, theme: tema
            )
        )
        #expect(
            longo.pixels(matching: tema.accentSoft, tolerance: 0.03) > 200,
            "o corpo longo tem de acender o aviso de que há mais abaixo"
        )
        #expect(
            curto.pixels(matching: tema.accentSoft, tolerance: 0.03) < 50,
            "o corpo que cabe inteiro não pode acender aviso nenhum"
        )
    }

    /// O esmaecimento: a última faixa do corpo longo pinta **menos** tinta do
    /// que a faixa do meio, porque o texto entra no véu de `paper` em vez de
    /// ser cortado ao meio por uma aresta dura.
    @Test("o corpo longo esmaece no fim em vez de ser cortado")
    func esmaecimento() throws {
        let tema = Theme.tinta
        let longo = try #require(
            Render.bitmap(
                CorpoRolavel(corpo: corpoLongo()).background(tema.paper.color),
                size: Self.colunaDaPrevia, theme: tema
            )
        )
        func tinta(_ linhas: Range<Int>) -> Int {
            var soma = 0
            for y in linhas {
                for x in 0..<longo.pixelsWide {
                    guard let cor = longo.colorAt(x: x, y: y) else { continue }
                    if cor.brightnessComponent < 0.6 { soma += 1 }
                }
            }
            return soma
        }
        let meio = tinta(120..<150)
        let fim = tinta(290..<300)
        #expect(meio > 0)
        #expect(fim < meio / 2, "a base do corpo tem de esmaecer (meio \(meio), fim \(fim))")
    }
}

@Suite("A fileira de ações não come o corpo")
@MainActor
struct PreviaAcoesTests {

    private static let coluna = CGSize(width: 380, height: 620)

    private func loja(_ message: Message) async -> MailStore {
        let store = MailStore(source: InMemoryMailSource(
            accounts: Fixtures.accounts, messages: [message], agenda: []
        ))
        await store.load()
        return store
    }

    private func painel(_ store: MailStore, _ message: Message) -> some View {
        let item = DashboardFocus.MailItem(message: message, reason: .needsReply)
        return DashboardPreviewPane(
            store: store,
            item: item,
            focus: DashboardFocus(
                mail: [item], meetings: [], pending: [],
                omittedMailCount: 0, omittedMeetingCount: 0, nextUpLabel: ""
            ),
            today: Fixtures.today,
            conversation: AssistantConversation(
                scope: .email,
                context: .init(subject: "Prévia"),
                destination: .unconfigured,
                engine: AssistantEngine(supportsDraftReply: false) { _ in "" }
            ),
            onOpen: {}, onCommand: { _ in }, onUseDraft: { _, _ in }, onEditDraft: { _, _ in }
        )
        .environment(ThemeStore())
    }

    /// **A prova**: a faixa de baixo — onde moram "Gerar resposta / Responder /
    /// Arquivar / Depois" — sai **idêntica** com um email de três linhas e com
    /// uma proposta de trinta. Se o corpo estivesse vazando por baixo dos
    /// botões, esses pixels mudariam.
    @Test("a faixa das ações é a mesma com o email curto e com o longo")
    func acoesNaoRecebemTextoPorBaixo() async throws {
        let tema = Theme.tinta
        let curta = QuatroEmails.mensagem(id: "curto", corpo: ["Oi, Marcos. Tudo certo."])
        let longa = QuatroEmails.mensagem(id: "longo", corpo: [QuatroEmails.proposta])

        let lojaCurta = await loja(curta)
        let lojaLonga = await loja(longa)

        let a = try #require(
            Render.bitmap(painel(lojaCurta, curta), size: Self.coluna, theme: tema)
        )
        let b = try #require(
            Render.bitmap(painel(lojaLonga, longa), size: Self.coluna, theme: tema)
        )
        let altura = Int(Self.coluna.height)
        #expect(
            a.pixelsDiffering(from: b, inColumns: 0..<a.pixelsWide, rows: (altura - 44)..<altura)
                == 0,
            "o corpo longo mudou os pixels da fileira de ações — está passando por baixo dela"
        )
        // E os dois desenhos **são** diferentes acima disso: senão o teste
        // acima passaria por acidente, com dois quadros iguais.
        #expect(a.pixelsDiffering(from: b, inColumns: 0..<a.pixelsWide, rows: 100..<300) > 0)
    }
}

/// Monta a coluna do meio inteira — cabeçalho, pedido, resumo, corpo e ações —
/// para a conferência humana dos PNGs.
@MainActor
enum PainelDeEnsaio {

    static func loja(_ message: Message) async -> MailStore {
        let store = MailStore(source: InMemoryMailSource(
            accounts: Fixtures.accounts, messages: [message], agenda: []
        ))
        await store.load()
        return store
    }

    static func painel(_ store: MailStore, _ message: Message) -> some View {
        let item = DashboardFocus.MailItem(message: message, reason: .needsReply)
        return DashboardPreviewPane(
            store: store,
            item: item,
            focus: DashboardFocus(
                mail: [item], meetings: [], pending: [],
                omittedMailCount: 0, omittedMeetingCount: 0, nextUpLabel: ""
            ),
            today: Fixtures.today,
            conversation: AssistantConversation(
                scope: .email,
                context: .init(subject: "Prévia"),
                destination: .unconfigured,
                engine: AssistantEngine(supportsDraftReply: false) { _ in "" }
            ),
            onOpen: {}, onCommand: { _ in }, onUseDraft: { _, _ in }, onEditDraft: { _, _ in }
        )
        .environment(ThemeStore())
    }
}

@Suite("Os quatro emails da caixa, desenhados")
@MainActor
struct QuatroEmailsRenderTests {

    /// **O critério de aceitação, com os olhos.** A prévia inteira dos quatro
    /// emails que o dono fotografou, nos dois temas.
    @Test("a prévia inteira dos quatro emails desenha em okami e em tinta")
    func previaInteira() async throws {
        let casos: [(String, Message)] = [
            ("previa-a-resend", QuatroEmails.mensagem(
                id: "a", assunto: "Welcome to Resend", html: QuatroEmails.resendHTML,
                resumo: "Zeno, fundador da Resend, dá três primeiros passos e pergunta por que você se inscreveu.",
                triagem: MessageTriage(needsReply: false, intent: .transactional, urgency: .low)
            )),
            ("previa-b-vantion", QuatroEmails.mensagem(
                id: "b", assunto: QuatroEmails.vantionAssunto, html: QuatroEmails.vantionHTML,
                resumo: "Maria Exemplo pediu orçamento de identidade visual pelo formulário do site.",
                triagem: MessageTriage(needsReply: true, intent: .lead, urgency: .normal)
            )),
            ("previa-c-proposta", QuatroEmails.mensagem(
                id: "c", assunto: "Expert consultation opportunity",
                corpo: [QuatroEmails.proposta],
                resumo: "Consultoria paga de 60 minutos, USD 250/h; querem sua disponibilidade em duas semanas.",
                triagem: MessageTriage(
                    needsReply: true, intent: .request, urgency: .high,
                    deadline: DetectedDeadline(
                        date: Fixtures.today.addingTimeInterval(3 * 86_400),
                        evidence: "available in the next two weeks"
                    )
                )
            )),
            ("previa-d-cadeia", QuatroEmails.mensagem(
                id: "d", assunto: "Re: o site novo", corpo: [QuatroEmails.cadeia],
                resumo: "Marina elogiou o site e não pediu nada.",
                triagem: MessageTriage(needsReply: false, intent: .informational, urgency: .low)
            )),
        ]
        for (nome, message) in casos {
            let store = await PainelDeEnsaio.loja(message)
            for tema in [Theme.okami, Theme.tinta] {
                let sufixo = tema.id == "tinta" ? "-tinta" : ""
                let rep = try #require(
                    Render.snapshot(
                        PainelDeEnsaio.painel(store, message)
                            .background(tema.paper.color),
                        named: "\(nome)\(sufixo)",
                        size: CGSize(width: 396, height: 620),
                        theme: tema
                    )
                )
                #expect(rep.pixelsHigh == 620)
            }
        }
    }

    @Test("os quatro emails renderizam em okami e em tinta")
    func osQuatroDesenham() throws {
        let casos: [(String, CorpoLegivel)] = [
            ("a-resend-html", CorpoLegivel.de(
                texto: "", html: QuatroEmails.resendHTML, assunto: "Welcome to Resend"
            )),
            ("b-vantion", CorpoLegivel.de(
                texto: "", html: QuatroEmails.vantionHTML, assunto: QuatroEmails.vantionAssunto
            )),
            ("c-proposta", CorpoLegivel.de(
                texto: QuatroEmails.proposta, html: nil,
                assunto: "Expert consultation opportunity"
            )),
            ("d-cadeia", CorpoLegivel.de(
                texto: QuatroEmails.cadeia, html: nil, assunto: "Re: o site novo"
            )),
        ]
        for (nome, corpo) in casos {
            for tema in [Theme.okami, Theme.tinta] {
                let sufixo = tema.id == "tinta" ? "-tinta" : ""
                let rep = try #require(
                    Render.snapshot(
                        CorpoRolavel(corpo: corpo)
                            .padding(16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .background(tema.paper.color),
                        named: "\(nome)\(sufixo)",
                        size: CGSize(width: 380, height: 420),
                        theme: tema
                    )
                )
                #expect(rep.pixelsWide == 380)
            }
        }
    }
}

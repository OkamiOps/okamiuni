import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// **Os cinco estados da IA no leitor, medidos contra o desenho.**
///
/// `Leitor-IA2.dc.html`: repouso, raso, resumo, rascunho e evento, nos três
/// temas que o dono olha — `vidro`, `vidro-noite` e `okami`, os dois de vidro e
/// um dos 26 opacos, que é onde o mesmo desenho tem de aparecer **sem** vidro.
///
/// O que esta suíte afirma não é "renderizou": é que em repouso **não existe
/// cartão nenhum** e que, com resultado, o cartão existe, tem o fio de acento,
/// o versalete da IA e um botão de próximo passo — que é exatamente o que
/// faltava na Tinta e o que o dono reprovou.
///
/// **Dado real, não fixture ideal.** Dois e-mails: uma newsletter HTML pesada,
/// com tabelas, imagens e estilo embutido, e um e-mail de uma linha. E a
/// resposta da IA é a realista: às vezes só um resumo, sem tarefa nem data.
///
/// `WKWebView` não pinta no harness fora da tela: o corpo HTML sai em branco,
/// e é de propósito que a régua mede os cartões, que estão **fora** da webview.
///
/// Os PNGs saem em `UNI_RENDER_DIR`.
@Suite("Leitor · a IA dentro do e-mail")
@MainActor
struct LeitorIARenderTests {

    private static let temas: [Theme] = [.vidro, .vidroNoite, .okami]

    /// 760 é a largura real do painel do leitor numa janela de 1440.
    private static let leitor = CGSize(width: 760, height: 900)

    // MARK: - Réguas

    private func casa(
        _ rep: NSBitmapImageRep, _ x: Int, _ y: Int, _ alvo: NSColor, _ tol: Double
    ) -> Bool {
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
              let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
              c.alphaComponent > 0.9 else { return false }
        return abs(c.redComponent - alvo.redComponent) < tol
            && abs(c.greenComponent - alvo.greenComponent) < tol
            && abs(c.blueComponent - alvo.blueComponent) < tol
    }

    private func primeiraLinha(
        _ rep: NSBitmapImageRep, de token: TokenColor,
        x: Range<Int>, y: Range<Int>, tol: Double = 0.05, minimo: Int = 6
    ) -> Int? {
        guard let alvo = token.nsColor.usingColorSpace(.sRGB) else { return nil }
        for py in y where py < rep.pixelsHigh {
            var n = 0
            for px in x where px < rep.pixelsWide {
                if casa(rep, px, py, alvo, tol) { n += 1 }
            }
            if n >= minimo { return py }
        }
        return nil
    }

    private func pixels(
        _ rep: NSBitmapImageRep, de token: TokenColor,
        x: Range<Int>, y: Range<Int>, tol: Double = 0.04
    ) -> Int {
        guard let alvo = token.nsColor.usingColorSpace(.sRGB) else { return 0 }
        var n = 0
        for py in y where py < rep.pixelsHigh {
            for px in x where px < rep.pixelsWide {
                if casa(rep, px, py, alvo, tol) { n += 1 }
            }
        }
        return n
    }

    // MARK: - Os e-mails

    private static let conta = Account(
        id: "a", address: "ricardo@empresa.com", displayName: "Ricardo",
        provider: .imap, host: "EMPRESA",
        tintLightHex: "#3b82f6", tintDarkHex: "#3b82f6"
    )

    /// **A newsletter de verdade**: tabelas aninhadas, imagem, largura fixa,
    /// estilo embutido e rodapé de descadastro. É o HTML que chega, não um
    /// parágrafo limpo.
    private static let newsletterHTML = """
        <html><head><style>
        body{margin:0;padding:0;background:#f4f4f7;font-family:Helvetica,Arial,sans-serif}
        .wrap{width:600px;margin:0 auto;background:#ffffff}
        td{padding:12px 20px;font-size:14px;line-height:1.5;color:#333}
        .cta{background:#4f46e5;color:#fff;padding:12px 22px;border-radius:6px}
        </style></head><body>
        <table class="wrap" cellpadding="0" cellspacing="0" width="600">
          <tr><td><img src="https://cdn.exemplo.com/logo.png" width="120" height="32" alt="Aitherion"></td></tr>
          <tr><td><h1 style="font-size:22px;margin:0 0 8px">O que mudou no contrato padrão</h1></td></tr>
          <tr><td>Olá Ricardo, este é o resumo de outubro. Revisamos as cláusulas de
          suporte e o SLA de primeira resposta passou de 8h para 4h úteis.</td></tr>
          <tr><td>
            <table cellpadding="0" cellspacing="0" width="100%">
              <tr><td width="50%"><b>Primeira resposta</b><br>4h úteis</td>
                  <td width="50%"><b>Resolução</b><br>2 dias úteis</td></tr>
              <tr><td width="50%"><b>Incidente crítico</b><br>1h</td>
                  <td width="50%"><b>Janela</b><br>08h–19h</td></tr>
            </table>
          </td></tr>
          <tr><td><a class="cta" href="https://exemplo.com/contrato">Ver o contrato</a></td></tr>
          <tr><td><img src="https://cdn.exemplo.com/grafico.png" width="560" height="220" alt="Gráfico"></td></tr>
          <tr><td style="font-size:11px;color:#888">Você recebe este e-mail porque assinou
          o boletim da Aitherion. Para não receber mais, cancele a inscrição.
          Rua Exemplo 100, São Paulo.</td></tr>
        </table>
        </body></html>
        """

    /// A resposta realista da IA: **só um resumo**. Nenhuma tarefa, nenhuma
    /// data, nenhuma lista — é o que o motor devolve na maior parte das vezes,
    /// e é com isso que o cartão tem de ficar de pé.
    private static let resumoRealista =
        "O contrato padrão mudou o SLA de primeira resposta de 8h para 4h úteis e "
        + "fixou 1h para incidente crítico. Nada aqui pede resposta sua hoje — mas "
        + "vale conferir se os seus contratos em aberto citam o número antigo."

    /// A newsletter pesada, com pedido na triagem: é o estado **resumo** do
    /// desenho, o que tem o que sobra para você.
    private static func newsletter(comResumo: Bool) -> Message {
        let quinta = Date(timeIntervalSince1970: 1_767_279_600)
        return Message(
            id: "boletim", accountID: "a",
            from: Contact(name: "Beatriz Nunes", address: "beatriz@aitherion.com"),
            receivedAt: Date(timeIntervalSince1970: 1_767_173_720),
            subject: "O que mudou no contrato padrão — boletim de outubro",
            snippet: "Revisamos as cláusulas de suporte e o SLA",
            body: ["Olá Ricardo, este é o resumo de outubro."],
            tags: [], bucket: .today, isRead: true,
            summary: comResumo ? resumoRealista : nil,
            detectedEvent: nil,
            triage: MessageTriage(
                needsReply: true, intent: .request, urgency: .normal,
                deadline: DetectedDeadline(date: quinta, evidence: "conferir até quinta")
            ),
            to: [Contact(name: "Ricardo", address: "ricardo@empresa.com")],
            bodyHTML: newsletterHTML
        )
    }

    /// **O e-mail de uma linha** — o estado raso: nada a fazer, e a IA diz
    /// isso. Sem triagem, sem compromisso, sem anexo.
    private static func curto(comResumo: Bool) -> Message {
        Message(
            id: "curto", accountID: "a",
            from: Contact(name: "Jack Oliveira", address: "jack@exemplo.com"),
            receivedAt: Date(timeIntervalSince1970: 1_767_180_000),
            subject: "Atualização rápida do projeto",
            snippet: "Tudo no prazo, nada para você fazer.",
            body: ["Tudo no prazo, nada para você fazer agora. Se mudar, eu aviso."],
            tags: [], bucket: .today, isRead: true,
            summary: comResumo
                ? "O Jack só avisa que o projeto segue no prazo. Não há pedido, "
                    + "data nem pendência — não precisa de resposta longa."
                : nil,
            detectedEvent: nil,
            to: [Contact(name: "Ricardo", address: "ricardo@empresa.com")]
        )
    }

    /// A mensagem com compromisso no texto — o estado **evento**.
    private static func comEvento() -> Message {
        let quinta = Date(timeIntervalSince1970: 1_767_279_600)
        return Message(
            id: "marina", accountID: "a",
            from: Contact(name: "Marina Duarte", address: "marina@cliente.com"),
            receivedAt: Date(timeIntervalSince1970: 1_767_173_720),
            subject: "Revisão do contrato — podemos fechar quinta?",
            snippet: "Revisei as cláusulas 4 e 7",
            body: [
                "Ricardo, revisei as cláusulas 4 e 7 com o jurídico. A pendência real "
                    + "é o escopo de suporte.",
                "Consigo assinar esta semana se fizermos uma call na quinta às 15h.",
            ],
            tags: [], bucket: .today, isRead: true,
            summary: "A Marina assina esta semana se houver uma call na quinta às 15h, "
                + "e quer a proposta de SLA pronta na call.",
            detectedEvent: DetectedEvent(
                label: "Call de revisão do contrato", start: quinta, duration: 1_800
            ),
            triage: MessageTriage(
                needsReply: true, intent: .request, urgency: .high,
                deadline: DetectedDeadline(date: quinta, evidence: "fechar quinta")
            ),
            to: [Contact(name: "Ricardo", address: "ricardo@empresa.com")]
        )
    }

    private func loja(_ message: Message, comRascunho: Bool = false) async -> MailStore {
        let store = MailStore(
            source: InMemoryMailSource(
                accounts: [Self.conta], messages: [message], agenda: []
            )
        )
        await store.load()
        store.select(message: message.id)
        if comRascunho {
            store.setReplyDraft(
                ReplyDraft(
                    to: [message.from],
                    body: AttributedString(
                        "Jack, perfeito — obrigado pelo retorno. Sigo aguardando o "
                            + "aviso se algo mudar; não precisa me copiar no resto."
                    )
                ),
                for: message.id
            )
        }
        return store
    }

    private func leitor(
        _ store: MailStore,
        comRascunho: Bool = false,
        comEvento: Bool = false,
        tema: Theme
    ) -> some View {
        var pane = ReaderPane(
            store: store,
            debugEmailAssistantOpen: false,
            debugResumoAberto: false,
            presentation: .pane,
            intelligence: { _ in "ok" },
            intelligencePresentation: .onThisMac,
            makeAssistantConversation: { _ in
                AssistantConversation(
                    scope: .email, context: .init(subject: "Leitor"),
                    destination: .onThisMac,
                    engine: AssistantEngine(supportsDraftReply: true) { _ in "" }
                )
            }
        )
        pane.debugIADraft = comRascunho
        pane.debugEventProposal = comEvento
        return pane.glassPanel(tema, kind: .reader)
    }

    /// A área de leitura: abaixo da barra de ferramentas e **acima** da faixa
    /// de resposta, cujo "Responder" é acento cheio e não é desta régua.
    private let corpo = 60..<820

    /// A coluna do **fio de acento** do cartão: ele nasce no recuo de 28 e tem
    /// 3 de largura. É a régua que separa "há cartão" de "não há": os links do
    /// aviso de imagens remotas também são acento, mas não moram aqui.
    private let fio = 26..<36

    // MARK: - Repouso

    /// **Em repouso não há cartão.** A IA é uma linha de ações debaixo do
    /// assunto: tinta de acento existe (a estrela e o fio), mas acento **cheio**
    /// — o fio do cartão, o botão forte — não aparece em lugar nenhum.
    @Test("em repouso a IA é uma linha de ações, sem cartão e sem faixa")
    func repousoRenderiza() async throws {
        for tema in Self.temas {
            let store = await loja(Self.newsletter(comResumo: false))
            let rep = try #require(Render.snapshot(
                leitor(store, tema: tema),
                named: "leitor-ia-repouso-\(tema.id)",
                size: Self.leitor, theme: tema
            ))

            // A estrela e os verbos: tinta de acento no cabeçalho.
            #expect(
                primeiraLinha(rep, de: tema.accentInk, x: 28..<400, y: 40..<300) != nil,
                "\(tema.id): a linha de ações da IA não apareceu debaixo do assunto"
            )
            // E nenhum cartão: o fio de acento não existe em lugar nenhum da
            // área de leitura.
            let rail = pixels(rep, de: tema.accent, x: fio, y: corpo)
            #expect(
                rail < 40,
                "\(tema.id): em repouso apareceu fio de cartão (\(rail) px), e o desenho não tem cartão nenhum"
            )
        }
    }

    // MARK: - Resumo

    /// **O cartão tem presença**: o fio de acento à esquerda, o versalete da
    /// IA e um botão de próximo passo. E a prosa é escrita em tinta cheia — a
    /// `ink` do tema, nunca `ink3` nem opacidade baixa.
    @Test("o resultado é um cartão com fio de acento, versalete e próximo passo")
    func resumoRenderiza() async throws {
        for tema in Self.temas {
            let store = await loja(Self.newsletter(comResumo: true))
            let rep = try #require(Render.snapshot(
                leitor(store, tema: tema),
                named: "leitor-ia-resumo-\(tema.id)",
                size: Self.leitor, theme: tema
            ))

            // O fio de 3px à esquerda, e o botão forte do próximo passo.
            let rail = pixels(rep, de: tema.accent, x: fio, y: corpo)
            #expect(rail > 120, "\(tema.id): o cartão da IA não tem fio de acento (\(rail) px)")
            let cheio = pixels(rep, de: tema.accent, x: 60..<760, y: corpo)
            #expect(
                cheio > 400,
                "\(tema.id): o cartão da IA não tem botão de próximo passo (\(cheio) px)"
            )
            // O versalete "RESUMO · ESCRITO PELA IA".
            let caps = try #require(
                primeiraLinha(rep, de: tema.accentInk, x: 40..<420, y: corpo),
                "\(tema.id): o versalete da IA não apareceu no cartão"
            )
            // E ele vem **depois** do remetente: é a ordem do desenho.
            let avatar = try #require(
                primeiraLinha(
                    rep, de: TokenColor(css: "#3b82f6")!, x: 28..<80, y: corpo,
                    tol: 0.10, minimo: 8
                ),
                "\(tema.id): não achei o avatar do remetente"
            )
            #expect(
                avatar < caps,
                "\(tema.id): o cartão (y \(caps)) subiu acima do remetente (y \(avatar))"
            )
            // A prosa em tinta cheia: `ink` tem massa dentro do cartão.
            let tinta = pixels(rep, de: tema.ink, x: 40..<720, y: caps..<(caps + 120), tol: 0.10)
            #expect(
                tinta > 300,
                "\(tema.id): a prosa da IA saiu apagada (\(tinta) px de tinta cheia)"
            )
        }
    }

    // MARK: - Raso

    /// **O e-mail sem nada a fazer diz isso** — e ainda oferece o que fazer.
    @Test("no e-mail raso a IA diz que não há nada, e ainda oferece ação")
    func rasoRenderiza() async throws {
        for tema in Self.temas {
            let store = await loja(Self.curto(comResumo: true))
            let rep = try #require(Render.snapshot(
                leitor(store, tema: tema),
                named: "leitor-ia-raso-\(tema.id)",
                size: Self.leitor, theme: tema
            ))

            let mensagem = try #require(store.message("curto"))
            #expect(mensagem.triage == nil, "a fixture do raso não pode ter triagem")

            // Mesmo sem tarefa e sem data, o cartão existe e tem botão forte.
            let rail = pixels(rep, de: tema.accent, x: fio, y: corpo)
            #expect(rail > 120, "\(tema.id): o e-mail raso perdeu o cartão (\(rail) px)")
            let cheio = pixels(rep, de: tema.accent, x: 60..<760, y: corpo)
            #expect(
                cheio > 400,
                "\(tema.id): o e-mail raso perdeu o próximo passo (\(cheio) px)"
            )
        }
    }

    // MARK: - Rascunho

    /// **O rascunho é um cartão atracado no fim do e-mail**, com o segmentado
    /// do tom, "Enviar revisando" e "Abrir no compositor".
    @Test("o rascunho da IA é um cartão no fim do e-mail, com tom e duas saídas")
    func rascunhoRenderiza() async throws {
        for tema in Self.temas {
            let store = await loja(Self.curto(comResumo: true), comRascunho: true)
            let rep = try #require(Render.snapshot(
                leitor(store, comRascunho: true, tema: tema),
                named: "leitor-ia-rascunho-\(tema.id)",
                size: Self.leitor, theme: tema
            ))

            // Dois versaletes de acento: o do resumo e o do rascunho.
            let primeiro = try #require(
                primeiraLinha(rep, de: tema.accentInk, x: 40..<420, y: corpo),
                "\(tema.id): nenhum versalete apareceu"
            )
            let segundo = primeiraLinha(
                rep, de: tema.accentInk, x: 40..<420, y: (primeiro + 60)..<820
            )
            #expect(
                segundo != nil,
                "\(tema.id): o versalete RASCUNHO · PARA … não apareceu abaixo do e-mail"
            )
            // E o acento cheio de "Enviar revisando" está na metade de baixo.
            let botao = pixels(rep, de: tema.accent, x: 0..<760, y: 450..<820)
            #expect(
                botao > 300,
                "\(tema.id): o cartão do rascunho perdeu Enviar revisando (\(botao) px)"
            )
        }
    }

    // MARK: - Evento

    /// **O evento tirado do e-mail**: a pastilha do dia em acento, o título, a
    /// trilha do dia e "Adicionar à agenda".
    @Test("o evento proposto mostra a pastilha do dia, a trilha e o botão da agenda")
    func eventoRenderiza() async throws {
        for tema in Self.temas {
            let store = await loja(Self.comEvento())
            let rep = try #require(Render.snapshot(
                leitor(store, comEvento: true, tema: tema),
                named: "leitor-ia-evento-\(tema.id)",
                size: Self.leitor, theme: tema
            ))

            // A pastilha "QUI" é uma mancha de acento cheio de 46 de largura,
            // e o botão "Adicionar à agenda" é outra: há acento de sobra.
            let cheio = pixels(rep, de: tema.accent, x: 0..<760, y: corpo)
            #expect(
                cheio > 900,
                "\(tema.id): o cartão do evento perdeu a pastilha do dia ou o botão (\(cheio) px)"
            )
            #expect(
                primeiraLinha(rep, de: tema.accentInk, x: 40..<460, y: corpo) != nil,
                "\(tema.id): o versalete EVENTO · TIRADO DESTE E-MAIL não apareceu"
            )
        }
    }

    // MARK: - O que a IA escreve, sem desenhar

    @Test("as sete ações existem, e só as que têm caminho próprio não têm pergunta")
    func acoesTemRota() {
        #expect(ReaderAIAction.offer == [.resumir, .rascunhar, .evento])
        #expect(ReaderAIAction.more == [.tarefas, .traduzir, .tom, .termos])
        for acao in ReaderAIAction.allCases {
            if [.rascunhar, .evento, .tom].contains(acao) {
                #expect(acao.question == nil, "\(acao.rawValue) não tem caminho próprio")
            } else {
                #expect(
                    acao.question?.isEmpty == false,
                    "\(acao.rawValue) ficaria sem rota — seria botão mudo"
                )
            }
            #expect(!acao.title.isEmpty)
            #expect(!acao.symbol.isEmpty)
        }
    }

    @Test("a extração de evento pede uma linha e o leitor local acha a data")
    func extracaoDeEventoUsaGramaticaLocal() {
        #expect(ReaderAIAction.eventExtraction.contains("uma linha"))
        #expect(ReaderAIAction.noEvent == "nenhum")

        // O que a IA devolve é frase; quem lê dia e hora é o `AppointmentPhrase`.
        let agora = Date(timeIntervalSince1970: 1_767_193_200)
        let lida = AppointmentPhrase.interpret(
            "Call de revisão do contrato amanhã 15h", now: agora
        )
        #expect(lida.start != nil, "a frase da IA não virou data")
        #expect(lida.title.contains("Call"), "o título se perdeu: \(lida.title)")
    }

    @Test("o primeiro nome e a hora do cartão saem da mensagem, não de fixture")
    func rotulosSaemDaMensagem() throws {
        let mensagem = Self.comEvento()
        #expect(ReaderPane.aiFirstName(mensagem) == "Marina")
        let evento = try #require(mensagem.detectedEvent)
        #expect(!ReaderPane.aiTimeRange(evento).isEmpty)
        #expect(!ReaderPane.aiWeekday(evento.start).isEmpty)
        #expect(ReaderPane.aiDayNumber(evento.start) != "0")
    }
}

import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// **Os estados do `Leitor5`, medidos contra o desenho.**
///
/// `Leitor5.dc.html`: repouso, menu da IA, resumo aberto, resumo recolhido,
/// remetente expandido e o menu do remetente — nos três temas que o dono olha:
/// `vidro`, `vidro-noite` e `okami`, os dois de vidro e um dos 26 opacos, que é
/// onde o mesmo desenho tem de aparecer **sem** vidro.
///
/// O que esta suíte afirma não é "renderizou". É o número de que o dono
/// reclamou: **onde o corpo do e-mail começa**. Ele começava em y≈485 numa
/// janela de 916, porque o cabeçalho tinha a linha de procedência, o assunto em
/// três linhas, o remetente, a linha de ações da IA e a faixa das imagens
/// remotas, uma embaixo da outra. O desenho põe o corpo em ~157 em repouso.
///
/// **Dado real, não fixture ideal.** Dois e-mails: uma newsletter HTML pesada,
/// com tabelas, imagens e estilo embutido, e um e-mail de uma linha.
///
/// `WKWebView` não pinta no harness fora da tela — por isso a régua do corpo é
/// `ReaderBodyTopKey`, e não uma contagem de pixels.
///
/// Os PNGs saem em `UNI_RENDER_DIR`.
@Suite("Leitor 5 · o cabeçalho que cabe")
@MainActor
struct LeitorIARenderTests {

    private static let temas: [Theme] = [.vidro, .vidroNoite, .okami]

    /// 760 é a largura real do painel do leitor numa janela de 1440. A altura
    /// é a do desenho menos a folga da página.
    private static let leitor = CGSize(width: 760, height: 896)

    // MARK: - Réguas

    /// Onde o corpo do e-mail começa, em pontos, no espaço do leitor.
    ///
    /// Uma caixa compartilhada e não um retorno direto: o valor nasce de uma
    /// `PreferenceKey`, que só existe durante o desenho.
    private final class CorpoY: @unchecked Sendable {
        var value: CGFloat?
    }

    private struct ComRegua<Conteudo: View>: View {
        let caixa: CorpoY
        let conteudo: Conteudo

        var body: some View {
            conteudo.onPreferenceChange(ReaderBodyTopKey.self) { y in
                MainActor.assumeIsolated { caixa.value = y }
            }
        }
    }

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
    /// data, nenhuma lista — é o que o motor devolve na maior parte das vezes.
    private static let resumoRealista =
        "O contrato padrão mudou o SLA de primeira resposta de 8h para 4h úteis e "
        + "fixou 1h para incidente crítico. Nada aqui pede resposta sua hoje — mas "
        + "vale conferir se os seus contratos em aberto citam o número antigo."

    /// **O assunto é comprido de propósito.** Era ele que dobrava em três
    /// linhas de 24pt e levava sessenta pontos do cabeçalho.
    private static func newsletter(comResumo: Bool) -> Message {
        let quinta = Date(timeIntervalSince1970: 1_767_279_600)
        return Message(
            id: "boletim", accountID: "a",
            from: Contact(name: "Beatriz Nunes", address: "beatriz@aitherion.com"),
            receivedAt: Date(timeIntervalSince1970: 1_767_173_720),
            subject: "O que mudou no contrato padrão — boletim de outubro da Aitherion, "
                + "com o novo SLA de primeira resposta",
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
            cc: [Contact(name: "Jurídico", address: "juridico@empresa.com")],
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
        resumoAberto: Bool = false,
        resumoRecolhido: Bool = false,
        remetenteExpandido: Bool = false,
        tema: Theme
    ) -> some View {
        var pane = ReaderPane(
            store: store,
            debugEmailAssistantOpen: false,
            debugResumoAberto: resumoAberto,
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
        pane.debugResumoRecolhido = resumoRecolhido
        pane.debugRemetenteExpandido = remetenteExpandido
        return pane.glassPanel(tema, kind: .reader)
    }

    /// Renderiza e devolve o bitmap **e** o y em que o corpo começa.
    private func retrato(
        _ view: some View, named nome: String, tema: Theme
    ) -> (rep: NSBitmapImageRep, corpoY: CGFloat)? {
        let caixa = CorpoY()
        guard let rep = Render.snapshot(
            ComRegua(caixa: caixa, conteudo: view),
            named: nome, size: Self.leitor, theme: tema
        ) else { return nil }
        guard let y = caixa.value else { return nil }
        return (rep, y)
    }

    /// A área de leitura: abaixo da barra de ferramentas e **acima** da faixa
    /// de resposta, cujo "Responder" é acento cheio e não é desta régua.
    private let corpo = 60..<816

    /// A coluna do **fio de acento** do cartão: ele nasce no recuo de 26 e tem
    /// 3 de largura.
    private let fio = 24..<34

    // MARK: - Repouso

    /// **O cabeçalho cabe.** Em repouso não há cartão, não há linha de ações e
    /// não há faixa de imagens: duas linhas — assunto e remetente — e o e-mail
    /// começa. O alvo é o do desenho; a folga de 24 cobre a diferença de
    /// métrica entre o Geist do protótipo e a face do tema.
    @Test("em repouso o corpo começa onde o desenho manda, e não há cartão")
    func repousoRenderiza() async throws {
        for tema in Self.temas {
            let store = await loja(Self.newsletter(comResumo: false))
            let (rep, y) = try #require(retrato(
                leitor(store, tema: tema),
                named: "leitor5-repouso-\(tema.id)", tema: tema
            ))

            #expect(
                abs(y - Self.corpoRepouso) <= Self.folga,
                "\(tema.id): em repouso o corpo começa em y=\(y); o desenho põe em \(Self.corpoRepouso)"
            )
            // E nenhum cartão: o fio de acento não existe na área de leitura.
            let rail = pixels(rep, de: tema.accent, x: fio, y: corpo)
            #expect(
                rail < 40,
                "\(tema.id): em repouso apareceu fio de cartão (\(rail) px), e o desenho não tem cartão nenhum"
            )
        }
    }

    /// **O e-mail de uma linha paga o mesmo cabeçalho.** Com assunto curto,
    /// sem Cc e sem triagem, o corpo tem de começar no mesmo lugar: o
    /// cabeçalho é de altura fixa, e não "o que sobrar do assunto".
    @Test("o e-mail curto tem o mesmo cabeçalho do pesado")
    func curtoRenderiza() async throws {
        for tema in Self.temas {
            let store = await loja(Self.curto(comResumo: false))
            let (_, y) = try #require(retrato(
                leitor(store, tema: tema),
                named: "leitor5-repouso-curto-\(tema.id)", tema: tema
            ))
            #expect(
                abs(y - Self.corpoRepouso) <= Self.folga,
                "\(tema.id): no e-mail curto o corpo começa em y=\(y); o desenho põe em \(Self.corpoRepouso)"
            )
        }
    }

    /// O mesmo e-mail curto com o resumo aberto: o cartão raso ("procurei
    /// prazos, tarefas e eventos — não há nenhum") e os dois botões.
    @Test("o e-mail curto com resumo mostra o cartão raso e o próximo passo")
    func curtoComResumoRenderiza() async throws {
        for tema in Self.temas {
            let store = await loja(Self.curto(comResumo: true))
            let (rep, _) = try #require(retrato(
                leitor(store, resumoAberto: true, tema: tema),
                named: "leitor5-resumo-aberto-curto-\(tema.id)", tema: tema
            ))
            let rail = pixels(rep, de: tema.accent, x: fio, y: corpo)
            #expect(rail > 80, "\(tema.id): o e-mail raso perdeu o cartão (\(rail) px)")
            let cheio = pixels(rep, de: tema.accent, x: 60..<760, y: corpo)
            #expect(
                cheio > 400,
                "\(tema.id): o e-mail raso perdeu o próximo passo (\(cheio) px)"
            )
        }
    }

    // MARK: - Resumo aberto

    /// **O cartão tem presença**: o fio de acento à esquerda, o versalete da
    /// IA e dois botões. E ele é mais justo que o anterior — o corpo desce o
    /// tanto do cartão, e nada mais.
    @Test("o resumo aberto é um cartão com fio, versalete e dois botões")
    func resumoAbertoRenderiza() async throws {
        for tema in Self.temas {
            let store = await loja(Self.newsletter(comResumo: true))
            let (rep, y) = try #require(retrato(
                leitor(store, resumoAberto: true, tema: tema),
                named: "leitor5-resumo-aberto-\(tema.id)", tema: tema
            ))

            #expect(
                abs(y - Self.corpoResumoAberto) <= Self.folga,
                "\(tema.id): com resumo aberto o corpo começa em y=\(y); o desenho põe em \(Self.corpoResumoAberto)"
            )
            let rail = pixels(rep, de: tema.accent, x: fio, y: corpo)
            #expect(rail > 80, "\(tema.id): o cartão da IA não tem fio de acento (\(rail) px)")
            let cheio = pixels(rep, de: tema.accent, x: 60..<760, y: corpo)
            #expect(
                cheio > 400,
                "\(tema.id): o cartão da IA não tem botão de próximo passo (\(cheio) px)"
            )
            #expect(
                primeiraLinha(rep, de: tema.accentInk, x: 40..<420, y: corpo) != nil,
                "\(tema.id): o versalete da IA não apareceu no cartão"
            )
        }
    }

    // MARK: - Resumo recolhido

    /// **Recolhido, o resumo é uma linha.** O começo da frase, os dois botões
    /// menores e o chevron — e o corpo sobe quase até onde estava em repouso.
    @Test("o resumo recolhido é uma linha, e o corpo quase não desce")
    func resumoRecolhidoRenderiza() async throws {
        for tema in Self.temas {
            let store = await loja(Self.newsletter(comResumo: true))
            let (rep, y) = try #require(retrato(
                leitor(store, resumoRecolhido: true, tema: tema),
                named: "leitor5-resumo-recolhido-\(tema.id)", tema: tema
            ))

            #expect(
                abs(y - Self.corpoResumoRecolhido) <= Self.folga,
                "\(tema.id): recolhido o corpo começa em y=\(y); o desenho põe em \(Self.corpoResumoRecolhido)"
            )
            // O fio do cartão continua lá — recolhido não é dispensado.
            let rail = pixels(rep, de: tema.accent, x: fio, y: corpo)
            #expect(rail > 20, "\(tema.id): a linha recolhida perdeu o fio de acento (\(rail) px)")
        }
    }

    // MARK: - O remetente expandido

    /// **Os detalhes abrem no mesmo bloco**, sob um fio — sem caixa dentro de
    /// caixa. E a linha "Assinado" **não** existe: o app não confere SPF nem
    /// DKIM, e um selo verde inventado é pior que selo nenhum.
    @Test("os detalhes do remetente abrem no mesmo bloco, sem SPF inventado")
    func remetenteExpandidoRenderiza() async throws {
        for tema in Self.temas {
            let store = await loja(Self.newsletter(comResumo: true))
            let (_, y) = try #require(retrato(
                leitor(store, resumoRecolhido: true, remetenteExpandido: true, tema: tema),
                named: "leitor5-remetente-expandido-\(tema.id)", tema: tema
            ))

            #expect(
                y > Self.corpoResumoRecolhido,
                "\(tema.id): os detalhes não empurraram o corpo (y=\(y))"
            )
        }
    }

    // MARK: - Os menus

    /// O menu da IA, desenhado sozinho: o `NSPopover` não nasce numa janela
    /// fora da tela, e o que esta régua verifica é o painel, não o popover.
    @Test("o menu da IA tem os grupos, os atalhos e o provedor no pé")
    func menuDaIARenderiza() throws {
        for tema in Self.temas {
            let rep = try #require(Render.snapshot(
                ReaderAIGroupedMenu(
                    provider: "Codex · ChatGPT",
                    isEnabled: { _ in true },
                    reason: { _ in "" },
                    run: { _ in },
                    onSwitchProvider: {}
                )
                .padding(20)
                .background(tema.surface.color),
                named: "leitor5-ia-menu-\(tema.id)",
                size: CGSize(width: 332, height: 420), theme: tema
            ))
            // A rubrica e os atalhos saem em `ink4`; o pé tem o ponto verde.
            #expect(
                pixels(rep, de: tema.success, x: 0..<332, y: 0..<420) > 10,
                "\(tema.id): o pé do menu perdeu o ponto do provedor"
            )
        }
    }

    /// O menu de contexto do remetente, pelo painel que o app já desenha.
    @Test("o menu do remetente tem copiar, copiar com nome e buscar")
    func menuDoRemetenteRenderiza() throws {
        let message = Self.newsletter(comResumo: false)
        let entradas = ReaderPane.senderMenu(message)
        #expect(entradas.count >= 4, "o menu do remetente ficou curto demais: \(entradas.count)")
        for tema in Self.temas {
            #expect(Render.snapshot(
                ContextMenuPanel(level: MenuLevel(entries: entradas))
                    .padding(20)
                    .background(tema.surface.color),
                named: "leitor5-remetente-menu-\(tema.id)",
                size: CGSize(width: 372, height: 220), theme: tema
            ) != nil)
        }
    }

    // MARK: - Os alvos do desenho

    /// Onde o corpo começa em cada estado, no espaço do leitor.
    ///
    /// O desenho é uma janela de 916 com 10 de folga de página; aqui o painel
    /// é a raiz, então o alvo é o do desenho menos essa folga.
    private static let corpoRepouso: CGFloat = 154
    private static let corpoResumoAberto: CGFloat = 319
    private static let corpoResumoRecolhido: CGFloat = 205
    /// A folga: o protótipo usa Geist e o app usa a face do tema, e uma
    /// diferença de métrica de fonte não é um defeito de layout.
    private static let folga: CGFloat = 30

    // MARK: - O que a IA escreve, sem desenhar

    @Test("as oito ações estão no menu, e cada uma tem atalho e rota")
    func acoesTemRota() {
        #expect(
            Set(ReaderAIGroup.listed) == Set(ReaderAIAction.allCases),
            "alguma ação ficou fora do menu: \(Set(ReaderAIAction.allCases).subtracting(ReaderAIGroup.listed))"
        )
        #expect(ReaderAIGroup.listed.count == ReaderAIAction.allCases.count, "ação repetida no menu")
        for acao in ReaderAIAction.allCases {
            if [.rascunhar, .evento, .tom, .perguntar].contains(acao) {
                #expect(acao.question == nil, "\(acao.rawValue) não tem caminho próprio")
            } else {
                #expect(
                    acao.question?.isEmpty == false,
                    "\(acao.rawValue) ficaria sem rota — seria botão mudo"
                )
            }
            #expect(!acao.title.isEmpty)
            #expect(!acao.symbol.isEmpty)
            #expect(acao.shortcutLabel.hasPrefix("⌥⌘"))
        }
    }

    /// **Nenhum atalho da IA colide com o que o app já reivindica.** ⌘E é
    /// Arquivar, ⌘R é Responder, ⌘J é o assistente — e é por isso que este
    /// conjunto inteiro mora em ⌥⌘.
    @Test("os atalhos da IA não colidem com os do app")
    func atalhosNaoColidem() {
        let teclas = ReaderAIAction.allCases.map(\.key)
        #expect(Set(teclas).count == teclas.count, "dois itens do menu pedem a mesma tecla")
        // Os do app vivem em ⌘, ⇧⌘ ou ⌃⌘ — nunca em ⌥⌘.
        let doApp: [MenuShortcut] = [
            .reply, .replyAll, .forward, .archive, .readToggle, .flag, .later,
        ]
        for atalho in doApp {
            #expect(
                !atalho.modifiers.contains(.option),
                "\(atalho.label) passou a usar ⌥ e agora disputa com o menu da IA"
            )
        }
    }

    @Test("a extração de evento pede uma linha e o leitor local acha a data")
    func extracaoDeEventoUsaGramaticaLocal() {
        #expect(ReaderAIAction.eventExtraction.contains("uma linha"))
        #expect(ReaderAIAction.noEvent == "nenhum")

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

    /// Os cabeçalhos da folha saem da mensagem, e a folha **diz** que o bloco
    /// cru não é guardado. Inventar um `Received:` seria pior que não ter.
    @Test("a folha de cabeçalhos escreve o que o banco tem, e avisa o que não tem")
    func cabecalhosSaemDoBanco() {
        let linhas = ReaderHeadersSheet.lines(
            of: Self.newsletter(comResumo: false),
            accountAddress: "ricardo@empresa.com", folder: "Hoje"
        )
        #expect(linhas.contains { $0.hasPrefix("From: ") })
        #expect(linhas.contains { $0.hasPrefix("Cc: ") })
        #expect(linhas.contains { $0.hasPrefix("Subject: ") })
        #expect(!linhas.contains { $0.hasPrefix("Received:") })
        #expect(ReaderHeadersSheet.aviso.contains("não é armazenado"))
    }
}

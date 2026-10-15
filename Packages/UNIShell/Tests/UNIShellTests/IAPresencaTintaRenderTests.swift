import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// **As duas direções aprovadas, desenhadas e medidas.**
///
/// `Mesa2.dc.html` (assistente) e `IA-Tinta.dc.html` (IA dentro do e-mail),
/// nos três temas que o dono olha: `vidro`, `vidro-noite` e `okami` — os dois
/// de vidro e um dos 26 opacos, que é onde o mesmo desenho tem de aparecer
/// **sem** o vidro.
///
/// O que esta suíte afirma não é "renderizou": é **posição e ordem**, que é o
/// que o dono reprovou três vezes. A régua sai do bitmap, nunca de uma
/// coordenada escrita à mão.
///
/// Os PNGs saem em `UNI_RENDER_DIR`.
@Suite("IA · Mesa e Tinta · desenho")
@MainActor
struct IAPresencaTintaRenderTests {

    private static let temas: [Theme] = [.vidro, .vidroNoite, .okami]

    /// O leitor do desenho mede 900 × 756 de janela; o painel dentro do shell
    /// é mais estreito, e 760 é a largura real dele numa janela de 1440.
    private static let leitor = CGSize(width: 760, height: 756)

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

    /// A primeira linha em que esta cor aparece, dentro de um recorte.
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

    /// O centro do aglomerado desta cor no recorte.
    private func centro(
        _ rep: NSBitmapImageRep, de token: TokenColor,
        x: Range<Int>, y: Range<Int>, tol: Double = 0.06, minimo: Int = 40
    ) -> CGPoint? {
        guard let alvo = token.nsColor.usingColorSpace(.sRGB) else { return nil }
        var somaX = 0, somaY = 0, n = 0
        for py in y where py < rep.pixelsHigh {
            for px in x where px < rep.pixelsWide {
                guard casa(rep, px, py, alvo, tol) else { continue }
                somaX += px; somaY += py; n += 1
            }
        }
        guard n >= minimo else { return nil }
        return CGPoint(x: Double(somaX) / Double(n), y: Double(somaY) / Double(n))
    }

    // MARK: - As fixtures

    /// Os estados aprovados da Mesa. **Dado real e esparso, não fixture
    /// ideal**: a nota curta é de uma linha, a longa tem lista, e a gaveta
    /// mínima tem uma conversa só com um cartão sem título.
    enum EstadoDaMesa: String, CaseIterable {
        case vazio
        case nota
        case notaLonga
        case trabalhando
        case rascunho
        case evento
        case gavetaMinima
        case semTitulo
    }

    private static let hora = Date(timeIntervalSince1970: 1_767_196_920)  // 16:02

    private func conversaDaMesa(_ estado: EstadoDaMesa) -> AssistantConversation {
        let hora = Self.hora
        func pergunta(_ texto: String) -> AssistantMessage {
            AssistantMessage(speaker: .user, text: texto, at: hora)
        }
        func resposta(
            _ texto: String, _ propostas: [AssistantProposal] = []
        ) -> AssistantMessage {
            AssistantMessage(
                speaker: .assistant, text: texto, proposals: propostas,
                at: hora.addingTimeInterval(3)
            )
        }

        let turnos: [AssistantMessage]
        switch estado {
        case .vazio:
            turnos = []
        case .trabalhando:
            turnos = [pergunta("Responde a Marina confirmando quinta e já prepara o convite")]
        case .nota:
            // Uma linha, e nada mais. É a resposta mais comum de verdade.
            turnos = [
                pergunta("O contrato da Marina fala em multa por atraso?"),
                resposta("Fala, sim — 2% ao mês, cláusula 9.2."),
            ]
        case .notaLonga:
            turnos = [
                pergunta("O que eu preciso resolver antes das 18h?"),
                resposta("""
                    Três coisas, e duas delas em até vinte minutos de trabalho seu.

                    - A Marina espera um sim para a call de quinta às 15h; você está livre.
                    - O Jayden mandou três e-mails sobre a consultoria e nenhum foi respondido.
                    - A fatura do Nubank fecha em três dias, e o valor é R$ 2.340,18.

                    O resto da caixa é disparo e pode ser arquivado junto.
                    """),
            ]
        case .rascunho:
            turnos = [
                pergunta("Responde a Marina confirmando quinta"),
                resposta(
                    "Escrevi o rascunho. Nada sai sem você rever.",
                    [AssistantProposal(
                        title: "Responder a Marina",
                        actions: [.reply(
                            messageID: "marina",
                            draft: "Marina, perfeito — quinta às 15h está de pé, já te mando "
                                + "o convite. Levo a proposta de SLA pronta: primeira resposta "
                                + "em 4h úteis e resolução em 2 dias úteis."
                        )],
                        rationale: "ela precisa de um sim para fechar esta semana"
                    )]
                ),
            ]
        case .evento:
            turnos = [
                pergunta("Marca a call da Marina"),
                resposta(
                    "Quinta às 15h está livre na sua agenda.",
                    [AssistantProposal(
                        title: "Call de revisão · qui 15:00–15:30",
                        actions: [.addToAgenda(messageID: "marina")],
                        rationale: "você e Marina · sem choque na agenda"
                    )]
                ),
            ]
        case .gavetaMinima:
            // Uma conversa só, e sem pergunta nenhuma antes dela.
            turnos = [resposta("Nenhum e-mail de hoje pede resposta.")]
        case .semTitulo:
            // O modelo devolveu proposta sem frase. O objeto não pode
            // desmontar por isso.
            turnos = [
                pergunta("arquiva o que é disparo"),
                resposta(
                    "",
                    [AssistantProposal(
                        title: "",
                        actions: [.archive(messageID: "abacus")],
                        rationale: ""
                    )]
                ),
            ]
        }

        return AssistantConversation(
            scope: .email,
            context: .init(subject: "Caixa e agenda de hoje"),
            destination: .init(label: "gpt-5.6-luna", detail: "neste Mac", isLocal: true),
            engine: AssistantEngine(supportsDraftReply: false) { _ in "" },
            debugState: AssistantPanelDebugState(
                messages: turnos, isLoading: estado == .trabalhando
            )
        )
    }

    /// A sessão com os passos reais de uma ida ao motor — dois cumpridos e um
    /// em curso, que é o que o desenho do "trabalhando" mostra.
    private func sessao(
        _ estado: EstadoDaMesa = .notaLonga, destacada: Bool = false
    ) -> AssistantSession {
        let s = AssistantSession(debugOpen: !destacada, debugDetached: destacada)
        s.adopt(conversaDaMesa(estado))
        s.ownerName = "Marcos"
        let inicio = Self.hora
        s.noteActivity("li 12 e-mails de hoje", at: inicio)
        s.noteActivity("olhando a agenda de quinta…", at: inicio.addingTimeInterval(1.2))
        if estado != .trabalhando {
            // A ida terminou: os passos viram recibo, com o tempo dela.
            s.noteActivity(nil, at: inicio.addingTimeInterval(2.4))
        }
        return s
    }

    /// O e-mail do desenho da Tinta: resumo guardado, um pedido com prazo e um
    /// compromisso detectado — as duas tarefas que a Tinta escreve em linha.
    private func lojaDoLeitor(comRascunho: Bool = false) async -> MailStore {
        let conta = Account(
            id: "a", address: "ricardo@empresa.com", displayName: "Ricardo",
            provider: .imap, host: "EMPRESA",
            tintLightHex: "#3b82f6", tintDarkHex: "#3b82f6"
        )
        let quinta = Date(timeIntervalSince1970: 1_767_279_600)
        let mensagem = Message(
            id: "marina", accountID: "a",
            from: Contact(name: "Marina Duarte", address: "marina@cliente.com"),
            receivedAt: Date(timeIntervalSince1970: 1_767_173_720),
            subject: "Revisão do contrato — podemos fechar quinta?",
            snippet: "Revisei as cláusulas 4 e 7",
            body: [
                "Ricardo, tudo bem? Revisei as cláusulas 4 e 7 com o jurídico. A única "
                    + "pendência real é o escopo de suporte — queremos deixar claro o SLA "
                    + "de resposta.",
                "Consigo assinar ainda esta semana se fizermos uma call na quinta às 15h. "
                    + "Sexta já entro em viagem e só volto no dia 15.",
                "Se puder, já leve uma proposta de SLA — assim fechamos tudo na mesma call.",
            ],
            tags: [], bucket: .today, isRead: true,
            summary: "Fecha com 2 ajustes, se houver call quinta às 15h — você está livre. "
                + "A pendência real é o SLA de suporte; sexta ela viaja e o contrato "
                + "escorrega para o dia 15.",
            detectedEvent: DetectedEvent(
                label: "Call quinta às 15h — você está livre",
                start: quinta, duration: 3_600
            ),
            triage: MessageTriage(
                needsReply: true, intent: .request, urgency: .high,
                deadline: DetectedDeadline(date: quinta, evidence: "fechar quinta")
            ),
            to: [Contact(name: "Ricardo", address: "ricardo@empresa.com")]
        )
        let store = MailStore(
            source: InMemoryMailSource(accounts: [conta], messages: [mensagem], agenda: [])
        )
        await store.load()
        store.select(message: "marina")
        if comRascunho {
            store.setReplyDraft(
                ReplyDraft(
                    to: [mensagem.from],
                    body: AttributedString(
                        "Marina, perfeito — quinta às 15h está de pé, já te mando o convite. "
                            + "Levo a proposta de SLA pronta: primeira resposta em 4h úteis, "
                            + "resolução em 2 dias úteis."
                    )
                ),
                for: "marina"
            )
        }
        return store
    }

    private func leitorView(_ store: MailStore, comRascunho: Bool) -> some View {
        ReaderPane(
            store: store,
            debugEmailAssistantOpen: false,
            debugResumoAberto: false,
            presentation: .pane,
            intelligence: { _ in "ok" },
            intelligencePresentation: .onThisMac,
            makeAssistantConversation: { _ in
                AssistantConversation(
                    scope: .email, context: .init(subject: "Revisão do contrato"),
                    destination: .onThisMac,
                    engine: AssistantEngine(supportsDraftReply: true) { _ in "" }
                )
            }
        )
        .iaDraftParaDesenho(comRascunho)
    }

    /// O leitor **dentro do painel**, que é como o shell o desenha: desde que
    /// todo tema tem `resolvedPanel`, o preenchimento é do painel e não do
    /// próprio leitor. Sem isto o retrato sai sobre o nada.
    private func leitorNoPainel(
        _ store: MailStore, comRascunho: Bool, tema: Theme
    ) -> some View {
        leitorView(store, comRascunho: comRascunho)
            .glassPanel(tema, kind: .reader)
    }

    /// A área da janela acima do campo: é onde os objetos da mesa moram, e o
    /// botão ↑ do campo (que é acento cheio, sempre) fica de fora.
    private static let acimaDoCampo = 0..<640

    // MARK: - Mesa · os semáforos de verdade

    /// O `Render` fotografa só a `contentView`: os semáforos nativos ficam de
    /// fora. Aqui a janela é titulada e eles entram na foto — precisam de
    /// folga da borda e caber na faixa de `TrafficLightLayout.windowBarHeight`.
    ///
    /// **Foi o conserto de duas rejeições, e a Mesa não o regride**: ela não
    /// pinta bolinha nenhuma, usa `trafficLightsInWindowHeader()` e só começa
    /// o conteúdo em `windowContentInset`. Por isso o caso roda nos três
    /// estados que a janela tem — se um deles mexesse na barra, só ele
    /// quebraria.
    @Test(
        "na janela real, os semáforos respiram e cabem no cabeçalho",
        arguments: [EstadoDaMesa.vazio, .notaLonga, .trabalhando]
    )
    func semaforosDaJanelaReal(_ estado: EstadoDaMesa) throws {
        for tema in Self.temas {
            let foto = try #require(JanelaReal.fotografar(
                AssistantWindow(session: sessao(estado, destacada: true))
                    .environment(ThemeStore()),
                size: MesaMetrics.windowSize, theme: tema,
                named: "mesa-janela-real-\(estado.rawValue)-\(tema.id)"
            ))
            let grupo = foto.grupo
            #expect(grupo.minX >= 18, "\(tema.id)/\(estado.rawValue): semáforos colados na borda (x=\(grupo.minX))")
            #expect(grupo.minY >= 10, "\(tema.id)/\(estado.rawValue): semáforos colados no topo (y=\(grupo.minY))")
            #expect(
                grupo.maxY <= TrafficLightLayout.windowBarHeight,
                "\(tema.id)/\(estado.rawValue): semáforos saem do cabeçalho (y=\(grupo.maxY))"
            )
            // E o conteúdo do cabeçalho começa **depois** da fileira: o
            // "Assistente" não pode encostar nela.
            #expect(
                grupo.maxX <= TrafficLightLayout.windowContentInset,
                "\(tema.id)/\(estado.rawValue): a fileira invadiu o recuo do conteúdo"
            )
        }
    }

    // MARK: - Mesa · os estados na janela

    /// Cada estado aprovado da Mesa, na janela de 880 × 744, nos três temas.
    ///
    /// A régua de cada estado é **o que o desenho promete ali**, medido no
    /// bitmap: o versalete do objeto em `accentInk`, o botão cheio em `accent`
    /// e o botão macio em `accentSoft`. A faixa para de 640 porque abaixo dela
    /// mora o botão ↑ do campo, que é acento cheio em todo estado.
    @Test(
        "os estados da Mesa desenham o que o desenho promete",
        arguments: EstadoDaMesa.allCases
    )
    func mesaRenderiza(_ estado: EstadoDaMesa) throws {
        for tema in Self.temas {
            let s = sessao(estado, destacada: true)
            let rep = try #require(Render.snapshot(
                AssistantWindow(session: s).environment(ThemeStore()),
                named: "mesa-\(estado.rawValue)-\(tema.id)",
                size: MesaMetrics.windowSize, theme: tema
            ))
            #expect(rep.pixelsWide == 880)
            #expect(rep.pixelsHigh == 744)

            let marca = "\(tema.id)/\(estado.rawValue)"
            let tinta = pixels(
                rep, de: tema.accentInk, x: 0..<880, y: Self.acimaDoCampo, tol: 0.08
            )
            let cheio = pixels(rep, de: tema.accent, x: 0..<880, y: Self.acimaDoCampo)
            let macio = pixels(
                rep, de: tema.accentSoft, x: 0..<880, y: Self.acimaDoCampo, tol: 0.02
            )

            switch estado {
            case .vazio:
                // A mesa vazia tem as setas das sugestões em acento e **nenhum
                // objeto**: nada de botão cheio em cima dela.
                #expect(tinta > 40, "\(marca): as sugestões não desenharam as setas")
                #expect(cheio < 200, "\(marca): a mesa vazia desenhou um botão de objeto")
            case .nota, .notaLonga, .gavetaMinima:
                // O versalete ✦ NOTA e a moldura de acento do objeto.
                #expect(tinta > 60, "\(marca): o objeto da nota perdeu o versalete")
            case .trabalhando:
                #expect(
                    s.steps == ["li 12 e-mails de hoje", "olhando a agenda de quinta…"],
                    "\(marca): a sessão não guardou os passos reais"
                )
                // O ✓ do passo cumprido é tinta de sucesso; o ponto que pulsa
                // é acento cheio. Os dois têm de estar na mesma faixa.
                #expect(
                    pixels(rep, de: tema.success, x: 0..<880, y: 0..<300, tol: 0.08) > 10,
                    "\(marca): o passo cumprido perdeu o ✓"
                )
                #expect(cheio > 30, "\(marca): o passo em curso perdeu o ponto que pulsa")
            case .rascunho:
                // "Abrir no compositor" é acento **cheio**: é o objeto que
                // leva a pessoa para fora da mesa.
                #expect(tinta > 60, "\(marca): o rascunho perdeu o versalete")
                #expect(cheio > 600, "\(marca): o rascunho perdeu o botão do compositor")
            case .evento, .semTitulo:
                // "Adicionar à agenda" é botão macio: `accentSoft` de fundo.
                #expect(macio > 400, "\(marca): o objeto perdeu o botão macio")
            }
        }
    }

    // MARK: - Mesa · a gaveta

    /// A mesma anatomia, em 400 — e com dado esparso: uma conversa só, e um
    /// cartão sem frase nenhuma.
    @Test(
        "a gaveta usa a mesma anatomia, em 400",
        arguments: [EstadoDaMesa.gavetaMinima, .semTitulo, .notaLonga, .vazio]
    )
    func gavetaRenderiza(_ estado: EstadoDaMesa) throws {
        for tema in Self.temas {
            let s = sessao(estado)
            let conversa = try #require(s.conversation)
            let rep = try #require(Render.snapshot(
                AssistantDrawer(
                    conversation: conversa,
                    session: s,
                    context: .day,
                    heroName: "Jayden Park",
                    onSwapContext: {}, onDetach: {}, onClose: {},
                    onRun: { _ in }, onReveal: { _ in }
                )
                .environment(ThemeStore()),
                named: "mesa-gaveta-\(estado.rawValue)-\(tema.id)",
                size: CGSize(width: AssistantDrawerMetrics.width, height: 744),
                theme: tema
            ))
            #expect(rep.pixelsWide == 400)

            // O ✦ do cabeçalho mora no recuo de 18 da gaveta, e é a primeira
            // tinta de acento dela.
            let recuo = Int(MesaMetrics.drawerHeaderPadding.leading)
            let sparkle = try #require(
                centro(
                    rep, de: tema.accentInk, x: recuo..<(recuo + 22), y: 0..<80,
                    tol: 0.10, minimo: 20
                ),
                "\(tema.id)/\(estado.rawValue): a gaveta perdeu o ✦ do cabeçalho"
            )
            #expect(
                sparkle.y < Double(MesaMetrics.drawerHeaderPadding.top) + 20,
                "\(tema.id)/\(estado.rawValue): o ✦ caiu do cabeçalho (y = \(sparkle.y))"
            )
        }
    }

    // MARK: - Tinta · o resumo e as tarefas no corpo

    @Test("a tinta da IA é escrita entre o assunto e o remetente")
    func tintaRenderiza() async throws {
        for tema in Self.temas {
            let store = await lojaDoLeitor()
            let rep = try #require(Render.snapshot(
                leitorNoPainel(store, comRascunho: false, tema: tema),
                named: "ia-tinta-leitor-\(tema.id)",
                size: Self.leitor, theme: tema
            ))

            // O versalete "✦ RESUMO E TAREFAS" é a primeira tinta de acento
            // depois do cabeçalho; o avatar do remetente é o azul da conta.
            let tinta = try #require(
                primeiraLinha(rep, de: tema.accentInk, x: 28..<400, y: 60..<700),
                "\(tema.id): a IA não escreveu nada no corpo do e-mail"
            )
            // E ela vem **antes** do remetente: é a ordem do desenho, e é a
            // razão de o remetente ter saído do cabeçalho fixo e entrado no
            // fluxo. O avatar é o azul da conta.
            //
            // E ela vem **antes** do remetente, nos 28 temas: é a ordem do
            // desenho, e é a razão de o remetente ter saído do cabeçalho fixo
            // e entrado no fluxo. O avatar é o azul da conta.
            let avatar = try #require(
                primeiraLinha(
                    rep, de: TokenColor(css: "#3b82f6")!, x: 28..<80, y: 60..<700,
                    tol: 0.10, minimo: 8
                ),
                "\(tema.id): não achei o avatar do remetente"
            )
            #expect(
                tinta < avatar,
                "\(tema.id): a tinta (y \(tinta)) caiu depois do remetente (y \(avatar))"
            )
        }
    }

    // MARK: - Tinta · o rascunho na barra de resposta

    @Test("o rascunho da IA mora na barra de resposta, com Revisar e enviar")
    func rascunhoNaBarraRenderiza() async throws {
        for tema in Self.temas {
            let store = await lojaDoLeitor(comRascunho: true)
            let rep = try #require(Render.snapshot(
                leitorNoPainel(store, comRascunho: true, tema: tema),
                named: "ia-tinta-rascunho-\(tema.id)",
                size: Self.leitor, theme: tema
            ))

            // "Revisar e enviar" é acento cheio, e mora **no pé** — é a barra
            // de resposta, não um cartão no meio do e-mail.
            let botao = pixels(rep, de: tema.accent, x: 0..<760, y: 600..<756)
            #expect(
                botao > 500,
                "\(tema.id): a barra de resposta não recebeu o rascunho da IA"
            )
            #expect(
                pixels(rep, de: tema.accentInk, x: 0..<760, y: 600..<756) > 80,
                "\(tema.id): o versalete RASCUNHO DA IA · TOM … não apareceu"
            )
        }
    }
}

private extension ReaderPane {
    /// A porta do harness para a barra de resposta com o rascunho da IA.
    func iaDraftParaDesenho(_ liga: Bool) -> Self {
        var copia = self
        copia.debugIADraft = liga
        return copia
    }
}

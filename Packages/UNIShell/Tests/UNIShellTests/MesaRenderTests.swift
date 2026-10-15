import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// **A Mesa, desenhada e medida.**
///
/// `design/Mesa2.dc.html` (estados `vazio`, `nota`, `trabalhando` e `gaveta`)
/// com os objetos `rascunho` e `evento` de `design/Leitor-IA.dc.html`, nos
/// três temas que o dono olha: `vidro`, `vidro-noite` e `okami` — os dois de
/// vidro e um dos 26 opacos, que é onde o mesmo desenho tem de aparecer
/// **sem** o vidro.
///
/// O que esta suíte afirma não é "renderizou": é **posição e ordem**, que é o
/// que o dono reprovou três vezes. A régua sai do bitmap, nunca de uma
/// coordenada escrita à mão.
///
/// As fixtures são de dado **real e esparso**, e não ideal: resposta de uma
/// linha, resposta longa com lista, gaveta com uma conversa só e cartão sem
/// título nenhum.
///
/// Os PNGs saem em `UNI_RENDER_DIR`.
@Suite("IA · Mesa · desenho")
@MainActor
struct MesaRenderTests {

    private static let temas: [Theme] = [.vidro, .vidroNoite, .okami]

    /// A área da janela acima do campo: é onde os objetos da mesa moram, e o
    /// botão ↑ do campo (que é acento cheio, sempre) fica de fora.
    private static let acimaDoCampo = 0..<640

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

    /// A última linha em que esta cor aparece, dentro de um recorte.
    private func ultimaLinha(
        _ rep: NSBitmapImageRep, de token: TokenColor,
        x: Range<Int>, y: Range<Int>, tol: Double = 0.05, minimo: Int = 6
    ) -> Int? {
        guard let alvo = token.nsColor.usingColorSpace(.sRGB) else { return nil }
        var ultima: Int?
        for py in y where py < rep.pixelsHigh {
            var n = 0
            for px in x where px < rep.pixelsWide {
                if casa(rep, px, py, alvo, tol) { n += 1 }
            }
            if n >= minimo { ultima = py }
        }
        return ultima
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
        case vazioComDia
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
        case .vazio, .vazioComDia:
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

    /// **O dia de verdade do dono**, pela mesma porta que a tela usa: o
    /// `DayPlan` do Painel, a agenda do dia e as promessas visíveis. Nada é
    /// montado à mão — se o construtor parar de achar o e-mail que espera, o
    /// retrato fica sem objeto e o caso acusa.
    private func diaDoDono() async -> [MesaDayItem] {
        let store = await DiaDoDono.loja()
        let plano = DashboardPlanInput.plan(
            store: store, drafts: [:], filter: .standard,
            today: DiaDoDono.agora, nowMinute: DiaDoDono.agoraMinuto
        )
        return MesaDayItem.items(
            plan: plano,
            agenda: store.dashboardAgenda(),
            pending: store.visiblePendingItems,
            today: DiaDoDono.agora,
            nowMinute: DiaDoDono.agoraMinuto
        )
    }

    /// A sessão com os passos reais de uma ida ao motor — dois cumpridos e um
    /// em curso, que é o que o desenho do "trabalhando" mostra.
    private func sessao(
        _ estado: EstadoDaMesa = .notaLonga,
        destacada: Bool = false,
        dia: [MesaDayItem] = []
    ) -> AssistantSession {
        let s = AssistantSession(debugOpen: !destacada, debugDetached: destacada)
        s.adopt(conversaDaMesa(estado))
        s.ownerName = "Marcos"
        s.dayItems = estado == .vazioComDia ? dia : []
        let inicio = Self.hora
        s.noteActivity("li 12 e-mails de hoje", at: inicio)
        s.noteActivity("olhando a agenda de quinta…", at: inicio.addingTimeInterval(1.2))
        if estado != .trabalhando {
            // A ida terminou: os passos viram recibo, com o tempo dela.
            s.noteActivity(nil, at: inicio.addingTimeInterval(2.4))
        }
        return s
    }

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
        arguments: [EstadoDaMesa.vazio, .vazioComDia, .notaLonga, .trabalhando]
    )
    func semaforosDaJanelaReal(_ estado: EstadoDaMesa) async throws {
        let dia = await diaDoDono()
        for tema in Self.temas {
            let foto = try #require(JanelaReal.fotografar(
                AssistantWindow(session: sessao(estado, destacada: true, dia: dia))
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
    func mesaRenderiza(_ estado: EstadoDaMesa) async throws {
        let dia = await diaDoDono()
        for tema in Self.temas {
            let s = sessao(estado, destacada: true, dia: dia)
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
                // A mesa limpa tem as setas das sugestões em acento e
                // **nenhum objeto**: nada de botão cheio em cima dela.
                #expect(tinta > 40, "\(marca): as sugestões não desenharam as setas")
                #expect(cheio < 200, "\(marca): a mesa limpa desenhou um botão de objeto")
                // E as sugestões sobem para junto da saudação: sem objeto, a
                // última delas não pode estar lá embaixo.
                let ultima = try #require(
                    ultimaLinha(rep, de: tema.accentInk, x: 0..<880, y: 0..<620, tol: 0.08),
                    "\(marca): não achei as setas das sugestões"
                )
                #expect(
                    ultima < 260,
                    "\(marca): a mesa limpa deixou um vão antes das sugestões (y = \(ultima))"
                )
            case .vazioComDia:
                // O dia do dono tem os três objetos, e eles são reais: três
                // versaletes e três botões macios.
                #expect(
                    s.dayItems.count == 3,
                    "\(marca): o dia do dono não rendeu três objetos (\(s.dayItems.count))"
                )
                #expect(macio > 400, "\(marca): os objetos do dia perderam os botões")
                #expect(tinta > 40, "\(marca): as sugestões sumiram da mesa posta")
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
        arguments: [EstadoDaMesa.gavetaMinima, .semTitulo, .notaLonga, .vazio, .vazioComDia]
    )
    func gavetaRenderiza(_ estado: EstadoDaMesa) async throws {
        let dia = await diaDoDono()
        for tema in Self.temas {
            let s = sessao(estado, dia: dia)
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
}

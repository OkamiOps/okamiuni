import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// **A Presença do assistente, desenhada e medida.**
///
/// `IA-Presenca.dc.html` — o assistente —, nos três temas que o dono olha:
/// `vidro`, `vidro-noite` e `okami`, os dois de vidro e um dos 26 opacos, que
/// é onde o mesmo desenho tem de aparecer **sem** o vidro.
///
/// A IA **dentro do e-mail** mudou de direção e mora em
/// `LeitorIARenderTests`: ver `Leitor-IA2.dc.html`.
///
/// O que esta suíte afirma não é "renderizou": é **posição e ordem**, que é o
/// que o dono reprovou três vezes. A régua sai do bitmap, nunca de uma
/// coordenada escrita à mão.
///
/// Os PNGs saem em `UNI_RENDER_DIR`.
@Suite("IA · Presença · desenho")
@MainActor
struct IAPresencaRenderTests {

    private static let temas: [Theme] = [.vidro, .vidroNoite, .okami]

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

    /// A pergunta e a resposta do desenho: três coisas, e a primeira já com
    /// rascunho pronto.
    private func conversaDoDesenho(
        carregando: Bool = false
    ) -> AssistantConversation {
        let hora = Date(timeIntervalSince1970: 1_767_196_920)  // 16:02
        let pergunta = AssistantMessage(
            speaker: .user,
            text: "O que eu preciso resolver antes das 18h?",
            at: hora
        )
        let resposta = AssistantMessage(
            speaker: .assistant,
            text: "Três coisas — e a primeira já tem resposta pronta.",
            proposals: [
                AssistantProposal(
                    title: "Jayden quer a consultoria paga — vence às 18h",
                    actions: [.reply(
                        messageID: "jayden",
                        draft: "Jayden, fechado — consigo amanhã às 10h ou às 15h. "
                            + "Me diz qual prefere que eu já mando o convite com o link da call."
                    )],
                    rationale: "ele espera desde ontem"
                ),
                AssistantProposal(
                    title: "Marina espera o seu ok na proposta",
                    actions: [.archive(messageID: "marina")],
                    rationale: "prazo sexta — o valor não mudou"
                ),
                AssistantProposal(
                    title: "Call com a Marina às 15h",
                    actions: [.addToAgenda(messageID: "marina")],
                    rationale: "em 40 minutos · o link está no convite"
                ),
            ],
            at: hora.addingTimeInterval(3)
        )
        return AssistantConversation(
            scope: .email,
            context: .init(subject: "Caixa e agenda de hoje"),
            destination: .init(label: "gpt-5.6-luna", detail: "", isLocal: false),
            engine: AssistantEngine(supportsDraftReply: false) { _ in "" },
            debugState: AssistantPanelDebugState(
                messages: carregando ? [pergunta] : [pergunta, resposta],
                isLoading: carregando
            )
        )
    }

    /// A sessão com os passos reais de uma ida ao motor — dois cumpridos e um
    /// em curso, que é o que o desenho do "trabalhando" mostra.
    private func sessao(
        carregando: Bool = false, destacada: Bool = false
    ) -> AssistantSession {
        let s = AssistantSession(debugOpen: !destacada, debugDetached: destacada)
        s.adopt(conversaDoDesenho(carregando: carregando))
        let inicio = Date(timeIntervalSince1970: 1_767_196_920)
        s.noteActivity("li 12 e-mails de hoje", at: inicio)
        s.noteActivity("olhando a agenda de quinta…", at: inicio.addingTimeInterval(1.2))
        if !carregando {
            // A ida terminou: os passos viram recibo, com o tempo dela.
            s.noteActivity(nil, at: inicio.addingTimeInterval(2.4))
        }
        return s
    }
    // MARK: - Presença · os semáforos de verdade

    /// O `Render` fotografa só a `contentView`: os semáforos nativos ficam de
    /// fora. Aqui a janela é titulada e eles entram na foto — precisam de
    /// folga da borda e caber no cabeçalho de 46.
    @Test("na janela real, os semáforos respiram e cabem no cabeçalho")
    func semaforosDaJanelaReal() throws {
        for tema in Self.temas {
            let foto = try #require(JanelaReal.fotografar(
                AssistantWindow(session: sessao(destacada: true)).environment(ThemeStore()),
                size: PresencaMetrics.windowSize, theme: tema,
                named: "ia-presenca-janela-real-\(tema.id)"
            ))
            let grupo = foto.grupo
            #expect(grupo.minX >= 18, "\(tema.id): semáforos colados na borda (x=\(grupo.minX))")
            #expect(grupo.minY >= 10, "\(tema.id): semáforos colados no topo (y=\(grupo.minY))")
            #expect(grupo.maxY <= TrafficLightLayout.windowBarHeight, "\(tema.id): semáforos saem do cabeçalho (y=\(grupo.maxY))")
        }
    }

    // MARK: - Presença · a resposta

    @Test("a resposta é um briefing numerado, e a janela tem as medidas do desenho")
    func respostaRenderiza() throws {
        for tema in Self.temas {
            let s = sessao(destacada: true)
            let rep = try #require(Render.snapshot(
                AssistantWindow(session: s).environment(ThemeStore()),
                named: "ia-presenca-resposta-\(tema.id)",
                size: PresencaMetrics.windowSize, theme: tema
            ))
            #expect(rep.pixelsWide == 880)
            #expect(rep.pixelsHigh == 744)

            // O "01" mora na coluna de 54 do recuo de 44: é a única tinta de
            // acento àquela altura, à esquerda do título.
            let recuo = Int(PresencaMetrics.gutter(forWidth: 880))
            let numero = pixels(
                rep, de: tema.accentInk,
                x: recuo..<(recuo + Int(PresencaMetrics.numberColumn)),
                y: 120..<700
            )
            #expect(numero > 60, "\(tema.id): o briefing não numerou os itens")

            // E o botão "Revisar e enviar" do rascunho é a mancha de acento
            // cheio dentro do item aberto.
            let botao = pixels(rep, de: tema.accent, x: recuo..<880, y: 120..<700)
            #expect(botao > 400, "\(tema.id): o rascunho do item 01 perdeu o botão")
        }
    }

    // MARK: - Presença · trabalhando

    @Test("trabalhando centraliza o orbe e lista os passos reais")
    func trabalhandoRenderiza() throws {
        for tema in Self.temas {
            let s = sessao(carregando: true, destacada: true)
            #expect(s.steps == ["li 12 e-mails de hoje", "olhando a agenda de quinta…"])
            let rep = try #require(Render.snapshot(
                AssistantWindow(session: s).environment(ThemeStore()),
                named: "ia-presenca-trabalhando-\(tema.id)",
                size: PresencaMetrics.windowSize, theme: tema
            ))

            // O orbe grande é a primeira mancha de acento da área de
            // trabalho, e ele é **centrado**: o desenho o põe no eixo da
            // janela, não à esquerda. A régua isola as 58 linhas dele para o
            // texto e a lista de passos não puxarem o centro.
            let topo = try #require(
                primeiraLinha(
                    rep, de: tema.accent, x: 200..<680, y: 100..<520,
                    tol: 0.18, minimo: 12
                ),
                "\(tema.id): não achei o orbe do estado trabalhando"
            )
            let orbe = try #require(
                centro(
                    rep, de: tema.accent, x: 200..<680,
                    y: topo..<(topo + Int(PresencaMetrics.bigOrbCore)),
                    tol: 0.18
                ),
                "\(tema.id): o orbe não tem massa nas 58 linhas do desenho"
            )
            #expect(
                abs(orbe.x - 440) < 24,
                "\(tema.id): o orbe saiu do eixo da janela (x = \(orbe.x))"
            )
        }
    }

    // MARK: - Presença · a gaveta

    @Test("a gaveta usa a mesma anatomia, em 440")
    func gavetaRenderiza() throws {
        for tema in Self.temas {
            let s = sessao()
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
                named: "ia-presenca-gaveta-\(tema.id)",
                size: CGSize(width: AssistantDrawerMetrics.width, height: 744),
                theme: tema
            ))
            #expect(rep.pixelsWide == 440)

            // O recuo da gaveta é 20: o número do item começa ali.
            let recuo = Int(PresencaMetrics.gutter(forWidth: 440))
            #expect(recuo == 20)
            let numero = pixels(
                rep, de: tema.accentInk,
                x: recuo..<(recuo + Int(PresencaMetrics.numberColumn)),
                y: 120..<620
            )
            #expect(numero > 40, "\(tema.id): a gaveta perdeu a numeração do briefing")
        }
    }

}


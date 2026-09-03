import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// A gaveta (09) e a janela (10) desenhadas, e clicadas.
///
/// **A régua do clique é medida no bitmap**, e não chutada: o alvo é o
/// aglomerado de `accent` do botão do cartão, no recorte da gaveta. Uma
/// coordenada escrita à mão passa a mentir no primeiro ajuste de medida.
@Suite("Gaveta e janela do assistente · desenho e clique")
@MainActor
struct AssistantDrawerRenderTests {

    private static let size = CGSize(width: 1_440, height: 916)
    /// A gaveta encosta na borda direita: este é o x onde ela começa.
    private static var drawerX: Int {
        Int(size.width - AssistantDrawerMetrics.width)
    }

    // MARK: - A fixture: a conversa do 09

    /// A porta de envio espiã, guardada fora da fixture para os testes a
    /// consultarem.
    private final class Envios: MailSendPort, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [OutgoingMessage] = []
        var sent: [OutgoingMessage] {
            lock.lock(); defer { lock.unlock() }
            return _sent
        }

        func send(_ message: OutgoingMessage) throws {
            lock.lock(); defer { lock.unlock() }
            _sent.append(message)
        }
    }

    /// O turno do 09: a pergunta, a resposta e um cartão que arquiva.
    private func conversaComCartao(
        _ acoes: [AssistantAction] = [.archive(messageID: "abacus")]
    ) -> AssistantConversation {
        AssistantConversation(
            scope: .email,
            context: .init(subject: "Caixa e agenda de hoje"),
            destination: .init(
                label: "Codex · ChatGPT", detail: "sai deste Mac", isLocal: false
            ),
            engine: AssistantEngine(supportsDraftReply: false) { _ in "" },
            debugState: AssistantPanelDebugState(messages: [
                AssistantMessage(speaker: .user, text: "arquiva tudo que é disparo hoje"),
                AssistantMessage(
                    speaker: .assistant,
                    text: "São 13: Welcome to Resend, Upwork, Zoho, Abacus e mais 9. "
                        + "Nenhum pede resposta.",
                    proposals: [AssistantProposal(
                        title: "13 emails vão para Arquivado. Dá para desfazer.",
                        actions: acoes,
                        rationale: "nenhum deles pede resposta"
                    )]
                ),
            ])
        )
    }

    private func tela(
        _ store: MailStore, session: AssistantSession
    ) -> some View {
        InboxScreen(
            store: store,
            clock: .fixed(DiaDoDono.agoraMinuto),
            readyDrafts: nil,
            assistantSession: session,
            debugAssistantOpen: false,
            debugWorkspace: .dashboard
        )
        .environment(ThemeStore())
    }

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
        x: Range<Int>, y: Range<Int>, tol: Double = 0.02
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

    /// O centro do maior aglomerado desta cor no recorte — o botão do cartão.
    private func centro(
        _ rep: NSBitmapImageRep, de token: TokenColor,
        x: Range<Int>, y: Range<Int>, tol: Double = 0.04
    ) -> CGPoint? {
        guard let alvo = token.nsColor.usingColorSpace(.sRGB) else { return nil }
        var somaX = 0, somaY = 0, n = 0
        for py in y where py < rep.pixelsHigh {
            for px in x where px < rep.pixelsWide {
                guard casa(rep, px, py, alvo, tol) else { continue }
                somaX += px; somaY += py; n += 1
            }
        }
        guard n > 40 else { return nil }
        return CGPoint(x: Double(somaX) / Double(n), y: Double(somaY) / Double(n))
    }

    // MARK: - Desenho

    @Test("a gaveta desenha sobre o dashboard, com o cartão de ação")
    func drawerRendersOverTheDashboard() async throws {
        for theme in [Theme.okami, Theme.tinta] {
            let store = await DiaDoDono.loja()
            let session = AssistantSession(debugOpen: true)
            session.adopt(conversaComCartao())

            let rep = try #require(Render.snapshot(
                tela(store, session: session),
                named: "gaveta-com-cartao-\(theme.id)",
                size: Self.size, theme: theme
            ))
            #expect(rep.pixelsWide == 1_440)

            // A gaveta ocupa os 440 da direita, em `surface`.
            let fundo = pixels(
                rep, de: theme.surface,
                x: (Self.drawerX + 8)..<1_440, y: 200..<800, tol: 0.012
            )
            #expect(fundo > 40_000, "\(theme.id): a gaveta não pintou surface")

            // E o botão do cartão é a mancha de accent dentro dela.
            let botao = pixels(
                rep, de: theme.accent, x: Self.drawerX..<1_440, y: 100..<600, tol: 0.03
            )
            #expect(botao > 400, "\(theme.id): o cartão de ação não desenhou o botão")
        }
    }

    /// Depois de executar, o cartão vira "Feito · Desfazer" — e o botão cheio
    /// sai da tela. É a diferença que a régua mede.
    @Test("executado, o cartão troca o botão por Feito · Desfazer")
    func executedCardShowsDoneAndUndo() async throws {
        let theme = Theme.okami
        let store = await DiaDoDono.loja()

        let antes = AssistantSession(debugOpen: true)
        antes.adopt(conversaComCartao())
        let repAntes = try #require(Render.snapshot(
            tela(store, session: antes),
            named: "gaveta-cartao-antes-\(theme.id)", size: Self.size, theme: theme
        ))

        let depois = AssistantSession(debugOpen: true)
        let conversa = conversaComCartao()
        depois.adopt(conversa)
        let cartao = try #require(conversa.messages.last?.cards.first)
        depois.markDone(cartao.id, undoing: UUID())
        let repDepois = try #require(Render.snapshot(
            tela(store, session: depois),
            named: "gaveta-cartao-feito-\(theme.id)", size: Self.size, theme: theme
        ))

        let cheio = pixels(
            repAntes, de: theme.accent, x: Self.drawerX..<1_440, y: 100..<600, tol: 0.03
        )
        let feito = pixels(
            repDepois, de: theme.accent, x: Self.drawerX..<1_440, y: 100..<600, tol: 0.03
        )
        #expect(cheio > 400)
        #expect(feito < cheio / 2, "o botão cheio continuou depois de executar")
    }

    @Test("a janela destacada desenha a mesma conversa, em 460 × 620")
    func detachedWindowRenders() async throws {
        for theme in [Theme.okami, Theme.tinta] {
            let session = AssistantSession(debugDetached: true)
            session.adopt(conversaComCartao())
            let rep = try #require(Render.snapshot(
                AssistantWindow(session: session).environment(ThemeStore()),
                named: "janela-assistente-\(theme.id)",
                size: AssistantDrawerMetrics.windowSize, theme: theme
            ))
            #expect(rep.pixelsWide == 460)
            #expect(rep.pixelsHigh == 620)
            let botao = pixels(
                rep, de: theme.accent, x: 0..<460, y: 0..<620, tol: 0.03
            )
            #expect(botao > 400, "\(theme.id): a janela perdeu o cartão de ação")
        }
    }

    // MARK: - Cliques

    /// **O clique executa; e é a única coisa que executa.** O verbo do cartão
    /// arquiva a mensagem pela fila de sempre — e a porta de envio continua
    /// vazia, como a §4 manda.
    @Test("clicar no verbo do cartão emite o comando certo, e nunca envia")
    func clickingTheVerbRunsTheCommand() async throws {
        let porta = Envios()
        let store = await DiaDoDono.loja(sendPort: porta)
        let session = AssistantSession(debugOpen: true)
        session.adopt(conversaComCartao())

        #expect(store.message("abacus")?.bucket == .today)

        let theme = Theme.tinta
        let rep = try #require(Render.bitmap(
            tela(store, session: session), size: Self.size, theme: theme
        ))
        let alvo = try #require(
            centro(rep, de: theme.accent, x: Self.drawerX..<1_440, y: 100..<600),
            "não achei o botão do cartão no desenho"
        )

        CliqueDeEnsaio.em(
            tela(store, session: session), size: Self.size,
            aY: alvo.y, x: alvo.x
        )

        #expect(store.message("abacus")?.bucket == .archived, "o cartão não arquivou")
        #expect(porta.sent.isEmpty, "o cartão encostou na porta de envio")
        #expect(session.isDone(try #require(
            session.conversation?.messages.last?.cards.first?.id
        )))
        // **O C1**: executar um cartão produz o recibo da leva, e o
        // "Desfazer" que ele mostra é o dessa leva — não o que estava na
        // barra por outro motivo.
        #expect(session.hasUndo, "o cartão executou sem deixar Desfazer nenhum")
        #expect(session.undoReceiptID != nil, "o Desfazer do cartão não aponta para recibo algum")
    }

    /// A leva inteira do cartão vira **um** recibo: os três arquivamentos
    /// saem juntos e o Desfazer é um só.
    @Test("a leva de três arquivamentos deixa um Desfazer só")
    func aBatchOfThreeLeavesOneUndo() async throws {
        let store = await DiaDoDono.loja()
        let session = AssistantSession(debugOpen: true)
        session.adopt(conversaComCartao([
            .archive(messageID: "abacus"),
            .archive(messageID: "carol"),
            .archive(messageID: "resend"),
        ]))

        let theme = Theme.tinta
        let rep = try #require(Render.bitmap(
            tela(store, session: session), size: Self.size, theme: theme
        ))
        let alvo = try #require(
            centro(rep, de: theme.accent, x: Self.drawerX..<1_440, y: 100..<600)
        )
        CliqueDeEnsaio.em(
            tela(store, session: session), size: Self.size, aY: alvo.y, x: alvo.x
        )

        for id in ["abacus", "carol", "resend"] {
            #expect(store.message(id)?.bucket == .archived, "\(id) não foi arquivada")
        }
        #expect(session.hasUndo, "a leva de três não deixou Desfazer")
        #expect(store.message("jack")?.bucket == .today, "a leva mexeu em quem não estava nela")
    }

    /// Uma leva **sem volta** (a reserva de bloco) diz "Feito" e não promete
    /// Desfazer nenhum.
    @Test("o cartão que reserva bloco não promete Desfazer")
    func aBlockReservationNeverPromisesUndo() async throws {
        let store = await DiaDoDono.loja()
        let session = AssistantSession(debugOpen: true)
        let conversa = conversaComCartao([
            .reserveBlock(day: 0, startMinute: 780, minutes: 20, title: "Responder"),
        ])
        session.adopt(conversa)

        let theme = Theme.tinta
        let rep = try #require(Render.bitmap(
            tela(store, session: session), size: Self.size, theme: theme
        ))
        let alvo = try #require(
            centro(rep, de: theme.accent, x: Self.drawerX..<1_440, y: 100..<600)
        )
        CliqueDeEnsaio.em(
            tela(store, session: session), size: Self.size, aY: alvo.y, x: alvo.x
        )

        let cartao = try #require(conversa.messages.last?.cards.first)
        #expect(session.isDone(cartao.id), "o cartão não executou")
        #expect(!session.hasUndo, "o cartão prometeu um Desfazer que não existe")
        #expect(!cartao.displayText.contains("desfazer"), "a frase prometeu desfazer")
    }

    /// **⏎ não executa nada.** Ele manda a pergunta, e só. A proposta que
    /// voltar continua sendo texto até alguém clicar.
    @Test("⏎ no campo manda a pergunta e não executa proposta nenhuma")
    func returnNeverRunsAProposal() async throws {
        let porta = Envios()
        let store = await DiaDoDono.loja(sendPort: porta)
        let session = AssistantSession()
        let conversa = AssistantConversation(
            scope: .email, context: .init(subject: "Hoje"),
            destination: .init(label: "Codex", detail: "", isLocal: false),
            engine: AssistantEngine(
                supportsDraftReply: false,
                answer: { _ in "" },
                answerWithProposals: { _ in
                    AssistantAnswer(
                        text: "Dá para arquivar.",
                        proposals: [AssistantProposal(
                            title: "13 emails vão para Arquivado.",
                            actions: [.archive(messageID: "abacus")],
                            rationale: "nenhum pede resposta"
                        )]
                    )
                }
            )
        )
        session.adopt(conversa)
        var comandos: [ContextCommand] = []
        session.install(runner: { _ in comandos.append(.openAccounts) }, reveal: { _ in })

        // É literalmente o que o `onSubmit` do campo chama.
        conversa.draft = "arquiva tudo que é disparo hoje"
        conversa.submit()
        await conversa.waitForIdle()

        #expect(conversa.messages.last?.cards.count == 1, "a proposta não virou cartão")
        #expect(comandos.isEmpty, "⏎ executou uma proposta")
        #expect(session.doneCards.isEmpty)
        #expect(porta.sent.isEmpty)
        #expect(store.message("abacus")?.bucket == .today, "⏎ mexeu na caixa")
    }

    /// O botão "Perguntar · ⌘J" do painel abre a **gaveta** — não o painel
    /// antigo. Ele mudou de lugar no 11: saiu do canto flutuante e foi para o
    /// fim da linha do cabeçalho, à direita do provedor.
    @Test("o botão Perguntar do cabeçalho abre a gaveta")
    func theHeaderButtonOpensTheDrawer() async throws {
        let store = await DiaDoDono.loja()
        let session = AssistantSession()
        // Fim da linha do cabeçalho do painel, logo abaixo do chrome.
        let x = Self.size.width - 94
        let y: CGFloat = 100

        CliqueDeEnsaio.em(tela(store, session: session), size: Self.size, aY: y, x: x)
        #expect(session.isDrawerOpen, "o botão do cabeçalho não abriu a gaveta")
    }

    /// ↗ destaca: abre a cena e **fecha a gaveta**. A mesma conversa em duas
    /// telas ao mesmo tempo é a definição de duplicidade.
    @Test("o ↗ destaca a conversa e fecha a gaveta")
    func detachButtonOpensTheSceneAndClosesTheDrawer() async throws {
        let store = await DiaDoDono.loja()
        let session = AssistantSession(debugOpen: true)
        let conversa = conversaComCartao()
        session.adopt(conversa)

        let theme = Theme.tinta
        let rep = try #require(Render.bitmap(
            tela(store, session: session), size: Self.size, theme: theme
        ))
        // Onde o cabeçalho da gaveta está: o ícone accent dele é a única
        // coisa em accent na coluna de entrada da gaveta. A gaveta começa
        // abaixo do chrome, então a altura não pode ser escrita à mão.
        let icone = try #require(
            centro(
                rep, de: theme.accent,
                x: (Self.drawerX + 12)..<(Self.drawerX + 44), y: 0..<400, tol: 0.06
            ),
            "não achei o ícone do cabeçalho da gaveta"
        )

        // Os dois ícones de ação são `ink3`, encostados na borda direita; o
        // da esquerda é o ↗.
        var colunas: [Int] = []
        let linhas = Int(icone.y - 10)..<Int(icone.y + 10)
        guard let alvo = theme.ink3.nsColor.usingColorSpace(.sRGB) else { return }
        for px in (1_440 - 120)..<1_440 {
            for py in linhas where casa(rep, px, py, alvo, 0.10) {
                colunas.append(px)
                break
            }
        }
        let esquerda = try #require(colunas.first, "não achei os ícones do cabeçalho")
        let direita = try #require(colunas.last)
        #expect(direita - esquerda > 10, "os dois ícones do cabeçalho viraram um")
        let alvoX = Double(esquerda) + Double(AssistantDrawerMetrics.headerActionSize) / 2

        CliqueDeEnsaio.em(
            tela(store, session: session), size: Self.size,
            aY: icone.y, x: alvoX
        )
        #expect(session.isDetached, "o ↗ não destacou")
        #expect(!session.isDrawerOpen, "a gaveta ficou aberta com a conversa destacada")
        // E a conversa é a mesma nos dois lugares.
        #expect(session.conversation === conversa)
    }

    // MARK: - ⌘J e Esc

    /// ⌘J abre e fecha a mesma gaveta. Ele mora no **menu principal** (ver
    /// `MessageCommands`) porque a gaveta abre com o foco no campo dela, e
    /// um `Button` escondido atrás de um campo focado nunca veria a tecla.
    @Test("⌘J abre e fecha a gaveta pela mesma porta")
    func commandJTogglesTheDrawer() async {
        let store = await DiaDoDono.loja()
        let session = AssistantSession()
        let tela = InboxScreen(
            store: store, assistantSession: session,
            debugAssistantOpen: false, debugWorkspace: .dashboard
        )
        tela.toggleDrawer()
        #expect(session.isDrawerOpen)
        tela.toggleDrawer()
        #expect(!session.isDrawerOpen)
    }

    @Test("Esc fecha a gaveta")
    func escapeClosesTheDrawer() async {
        let store = await DiaDoDono.loja()
        let session = AssistantSession(debugOpen: true)
        let tela = InboxScreen(
            store: store, assistantSession: session,
            debugAssistantOpen: false, debugWorkspace: .dashboard
        )
        #expect(tela.handleEscape(searchFocused: false))
        #expect(!session.isDrawerOpen)
    }

    /// Com a janela destacada, ⌘J **não** abre gaveta nenhuma: ele traz a
    /// janela. A mesma conversa em duas telas ao mesmo tempo é duplicidade.
    @Test("com a janela destacada, ⌘J não abre a gaveta")
    func commandJWithTheWindowDetached() async {
        let store = await DiaDoDono.loja()
        let session = AssistantSession(debugDetached: true)
        let tela = InboxScreen(
            store: store, assistantSession: session,
            debugAssistantOpen: false, debugWorkspace: .dashboard
        )
        tela.toggleDrawer()
        #expect(!session.isDrawerOpen)
    }

    /// A gaveta e a janela mostram **a mesma** conversa — o mesmo objeto, com
    /// o mesmo transcript e os mesmos cartões.
    @Test("a conversa é a mesma na gaveta e na janela")
    func theConversationIsTheSameInBothPlaces() async throws {
        let session = AssistantSession(debugOpen: true)
        let conversa = conversaComCartao()
        session.adopt(conversa)

        session.detach()
        let daJanela = try #require(session.conversation)
        #expect(daJanela === conversa)
        #expect(daJanela.messages.count == 2)
        #expect(daJanela.messages.last?.cards.count == 1)
    }

    /// **A gaveta é overlay, e nada atrás dela se mexe.** Se ela empurrasse a
    /// caixa, o herói do dashboard mudaria de coluna — e a pessoa perderia o
    /// parágrafo que estava lendo por ter feito uma pergunta.
    @Test("abrir a gaveta não move nada atrás dela")
    func openingTheDrawerMovesNothing() async throws {
        let theme = Theme.okami
        let store = await DiaDoDono.loja()

        // A régua é **posição**, e não cor: o esmaecimento a 45% muda a cor
        // de tudo que está atrás, e nada mais pode mudar.
        func mancha(_ session: AssistantSession) throws -> ClosedRange<Int> {
            let rep = try #require(Render.bitmap(
                tela(store, session: session), size: Self.size, theme: theme
            ))
            let fundo = try #require(theme.paper.nsColor.usingColorSpace(.sRGB))
            var menor = Int.max
            var maior = Int.min
            for px in 0..<Self.drawerX {
                for py in 100..<320 where !casa(rep, px, py, fundo, 0.02) {
                    menor = min(menor, px)
                    maior = max(maior, px)
                    break
                }
            }
            guard menor <= maior else {
                Issue.record("não achei conteúdo à esquerda da gaveta")
                return 0...0
            }
            return menor...maior
        }

        let fechada = try mancha(AssistantSession())
        let aberta = try mancha(AssistantSession(debugOpen: true))
        #expect(
            fechada == aberta,
            "o conteúdo andou quando a gaveta abriu (\(fechada) → \(aberta))"
        )
    }

    /// E o que está atrás **esmaece a 45%** — nem some, nem continua
    /// competindo com a gaveta pela atenção.
    @Test("o conteúdo atrás da gaveta fica a 45%")
    func theBackdropDimsToFortyFivePercent() async throws {
        let theme = Theme.okami
        let store = await DiaDoDono.loja()

        /// A distância média de cada pixel até o fundo da tela — a "tinta"
        /// que a coluna carrega. Esmaecer a 45% a corta pela metade.
        func tinta(_ session: AssistantSession) throws -> Double {
            let rep = try #require(Render.bitmap(
                tela(store, session: session), size: Self.size, theme: theme
            ))
            let fundo = try #require(theme.paper.nsColor.usingColorSpace(.sRGB))
            var soma = 0.0
            var n = 0
            for px in stride(from: 40, to: Self.drawerX, by: 3) {
                for py in stride(from: 120, to: 300, by: 3) {
                    guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else {
                        continue
                    }
                    soma += abs(c.redComponent - fundo.redComponent)
                        + abs(c.greenComponent - fundo.greenComponent)
                        + abs(c.blueComponent - fundo.blueComponent)
                    n += 1
                }
            }
            return n == 0 ? 0 : soma / Double(n)
        }

        let cheia = try tinta(AssistantSession())
        let esmaecida = try tinta(AssistantSession(debugOpen: true))
        #expect(cheia > 0.01, "não havia conteúdo para esmaecer")
        let razao = esmaecida / cheia
        #expect(
            abs(razao - AssistantDrawerMetrics.backdropOpacity) < 0.06,
            "o fundo ficou a \(razao) em vez de 0,45"
        )
    }
}

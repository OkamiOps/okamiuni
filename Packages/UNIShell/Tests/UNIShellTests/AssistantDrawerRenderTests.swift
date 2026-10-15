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

    /// **As faixas de linhas em que esta cor aparece**, na ordem — uma por
    /// aglomerado separado por pelo menos `vao` linhas limpas.
    ///
    /// É a régua que a Mesa pede: o `accentSoft` do desenho pinta duas coisas
    /// na gaveta, a lasca da pergunta no alto e o botão macio do objeto mais
    /// embaixo. Medir "o aglomerado" sem separá-los daria o ponto do meio, que
    /// não é nenhum dos dois.
    private func faixas(
        _ rep: NSBitmapImageRep, de token: TokenColor,
        x: Range<Int>, y: Range<Int>, tol: Double = 0.03, minimo: Int = 10, vao: Int = 6
    ) -> [ClosedRange<Int>] {
        guard let alvo = token.nsColor.usingColorSpace(.sRGB) else { return [] }
        var achadas: [ClosedRange<Int>] = []
        var inicio: Int?
        var ultima = 0
        for py in y where py < rep.pixelsHigh {
            var n = 0
            for px in x where px < rep.pixelsWide {
                if casa(rep, px, py, alvo, tol) { n += 1 }
            }
            if n >= minimo {
                if inicio == nil { inicio = py }
                ultima = py
            } else if let comeco = inicio, py - ultima > vao {
                achadas.append(comeco...ultima)
                inicio = nil
            }
        }
        if let comeco = inicio { achadas.append(comeco...ultima) }
        return achadas
    }

    /// **O botão primário do objeto da mesa.**
    ///
    /// No desenho da Mesa o objeto de proposta tem botão macio: `accentSoft`
    /// de fundo, verbo em `accentInk`, alinhado à **esquerda** dentro do
    /// objeto. A coluna sai do desenho (a margem da mesa mais o recuo do
    /// objeto); a linha sai do bitmap — é a última faixa de `accentSoft`, já
    /// que a primeira é a lasca da pergunta no alto.
    private func botaoDoObjeto(
        _ rep: NSBitmapImageRep, _ theme: Theme, xInicio: Int, xFim: Int
    ) -> CGPoint? {
        let coluna = Double(xInicio)
            + Double(MesaMetrics.mesaMargin.leading)
            + Double(MesaMetrics.objectGap)
            + Double(MesaMetrics.objectActionPadding.leading)
            + 24
        guard let banda = Self.faixaDoBotao(self, rep, theme, xInicio: xInicio) else {
            return nil
        }
        return CGPoint(x: coluna, y: Double(banda.lowerBound + banda.upperBound) / 2)
    }

    /// **A coluna estreita do botão, e não a gaveta inteira.**
    ///
    /// A mesa é pontilhada, e um ponto antialiasado sobre a parede cai bem
    /// perto de `accentSoft`: varrendo a gaveta toda, "a última faixa de
    /// acento macio" era uma fileira de pontos lá embaixo. Na coluna do botão
    /// os pontos somam meia dúzia por linha e o botão soma dezenas.
    private static func colunaDoBotao(_ xInicio: Int) -> Range<Int> {
        let inicio = xInicio + Int(MesaMetrics.mesaMargin.leading)
            + Int(MesaMetrics.objectGap) + Int(MesaMetrics.objectActionPadding.leading)
        return inicio..<(inicio + 120)
    }

    /// O botão **cheio** do objeto — o "Abrir no compositor" do rascunho, que
    /// é o único que tira a pessoa da mesa e por isso leva acento inteiro.
    /// Mesma coluna estreita; o ↑ do campo fica fora dela.
    private func botaoCheioDoObjeto(
        _ rep: NSBitmapImageRep, _ theme: Theme, xInicio: Int
    ) -> CGPoint? {
        let coluna = Self.colunaDoBotao(xInicio)
        guard let banda = faixas(
            rep, de: theme.accent, x: coluna, y: 60..<820, minimo: 40
        ).last else { return nil }
        return CGPoint(
            x: Double(coluna.lowerBound + 24),
            y: Double(banda.lowerBound + banda.upperBound) / 2
        )
    }

    private static func faixaDoBotao(
        _ suite: AssistantDrawerRenderTests,
        _ rep: NSBitmapImageRep, _ theme: Theme, xInicio: Int
    ) -> ClosedRange<Int>? {
        suite.faixas(
            rep, de: theme.accentSoft, x: colunaDoBotao(xInicio), y: 60..<820,
            minimo: 40
        ).last
    }

    /// O centro do maior aglomerado desta cor no recorte — o botão do cartão.
    private func centro(
        _ rep: NSBitmapImageRep, de token: TokenColor,
        x: Range<Int>, y: Range<Int>, tol: Double = 0.04, minimo: Int = 40
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

            // E o objeto da mesa traz o verbo em tinta de acento.
            let botao = pixels(
                rep, de: theme.accentInk,
                x: (Self.drawerX + 20)..<1_440, y: 60..<820, tol: 0.08
            )
            #expect(botao > 60, "\(theme.id): o objeto da mesa não desenhou o botão")
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

        // **O botão sai, e o que fica é texto.** No desenho da Mesa o objeto
        // de proposta tem botão macio, `accentSoft` de fundo; executado, ele
        // vira "Feito · Desfazer", que é tinta e mais nada. A régua é esse
        // fundo: a tinta de acento não serve, porque o "Desfazer" também é
        // acento.
        //
        // A régua corre na coluna do botão — ver `colunaDoBotao`: a lasca da
        // pergunta é à direita e os pontos da mesa não somam ali.
        let coluna = Self.colunaDoBotao(Self.drawerX)
        func fundoDoBotao(_ rep: NSBitmapImageRep) -> Int {
            guard let banda = Self.faixaDoBotao(self, rep, theme, xInicio: Self.drawerX)
            else { return 0 }
            return pixels(
                rep, de: theme.accentSoft, x: coluna,
                y: banda.lowerBound..<(banda.upperBound + 1), tol: 0.03
            )
        }
        let comBotao = fundoDoBotao(repAntes)
        let semBotao = fundoDoBotao(repDepois)
        #expect(comBotao > 400, "o objeto não desenhou o fundo do botão macio")
        #expect(
            semBotao < comBotao / 2,
            "o fundo do botão continuou depois de executar (\(comBotao) → \(semBotao))"
        )
    }

    /// A mesma garantia de antes — a janela destacada mostra a mesma conversa,
    /// com os mesmos itens — nas medidas do desenho aprovado: 880 × 744.
    @Test("a janela destacada desenha a mesma conversa, em 880 × 744")
    func detachedWindowRenders() async throws {
        for theme in [Theme.okami, Theme.tinta] {
            let session = AssistantSession(debugDetached: true)
            session.adopt(conversaComCartao())
            let rep = try #require(Render.snapshot(
                AssistantWindow(session: session).environment(ThemeStore()),
                named: "janela-assistente-\(theme.id)",
                size: AssistantDrawerMetrics.windowSize, theme: theme
            ))
            #expect(rep.pixelsWide == 880)
            #expect(rep.pixelsHigh == 744)
            let botao = pixels(
                rep, de: theme.accentInk, x: 200..<880, y: 100..<700, tol: 0.08
            )
            #expect(botao > 60, "\(theme.id): a janela perdeu o item do briefing")
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
            botaoDoObjeto(rep, theme, xInicio: Self.drawerX, xFim: 1_440),
            "não achei o botão do item no desenho"
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
            botaoDoObjeto(rep, theme, xInicio: Self.drawerX, xFim: 1_440)
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

    /// **O rascunho leva ao compositor, e não a lugar nenhum.**
    ///
    /// "Abrir no compositor" grava o rascunho pela mesma fila da Caixa
    /// (`MailAgentTools.saveReplyDraft`) e abre a janela da resposta. A prova
    /// é o rascunho na caixa de saída — e a porta de envio vazia, porque nada
    /// sai sem revisão.
    @Test("o rascunho abre o compositor e nunca envia")
    func theDraftObjectOpensTheComposer() async throws {
        let porta = Envios()
        let store = await DiaDoDono.loja(sendPort: porta)
        let session = AssistantSession(debugOpen: true)
        session.adopt(conversaComCartao([.reply(
            messageID: "jack",
            draft: "Jack, a página não exige login — te mando o link direto."
        )]))

        let antes = store.messages.filter { $0.bucket == .drafts }.count

        let theme = Theme.tinta
        let rep = try #require(Render.bitmap(
            tela(store, session: session), size: Self.size, theme: theme
        ))
        let alvo = try #require(
            botaoCheioDoObjeto(rep, theme, xInicio: Self.drawerX),
            "não achei o botão do rascunho"
        )
        CliqueDeEnsaio.em(
            tela(store, session: session), size: Self.size, aY: alvo.y, x: alvo.x
        )

        let depois = store.messages.filter { $0.bucket == .drafts }
        #expect(depois.count == antes + 1, "o rascunho não foi gravado")
        #expect(
            depois.contains { $0.body.joined().contains("não exige login") },
            "o rascunho gravado não é o que a Mesa mostrava"
        )
        #expect(porta.sent.isEmpty, "o rascunho encostou na porta de envio")
    }

    /// **O evento escreve na agenda.** O objeto de evento é o único cuja leva
    /// não volta atrás — e por isso ele diz "Feito" e nada mais.
    @Test("o evento proposto escreve na agenda")
    func theEventObjectWritesToTheAgenda() async throws {
        let store = await DiaDoDono.loja()
        let session = AssistantSession(debugOpen: true)
        session.adopt(conversaComCartao([
            .reserveBlock(day: 0, startMinute: 900, minutes: 30, title: "Call de revisão"),
        ]))

        let antes = store.agenda.count

        let theme = Theme.tinta
        let rep = try #require(Render.bitmap(
            tela(store, session: session), size: Self.size, theme: theme
        ))
        let alvo = try #require(
            botaoDoObjeto(rep, theme, xInicio: Self.drawerX, xFim: 1_440),
            "não achei o botão do evento"
        )
        CliqueDeEnsaio.em(
            tela(store, session: session), size: Self.size, aY: alvo.y, x: alvo.x
        )

        #expect(store.agenda.count == antes + 1, "o evento não entrou na agenda")
        #expect(
            store.agenda.contains { $0.title == "Call de revisão" },
            "entrou outra coisa na agenda"
        )
        #expect(!session.hasUndo, "a escrita de agenda prometeu um Desfazer que não existe")
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
            botaoDoObjeto(rep, theme, xInicio: Self.drawerX, xFim: 1_440)
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

    // O caso "o botão Perguntar do cabeçalho abre a gaveta" saiu daqui.
    //
    // Ele clicava no "Perguntar · ⌘J" do cabeçalho do Painel do Dia. Esse
    // botão **não é mais desenhado**: o shell novo trocou o cabeçalho do
    // painel ("Bom dia, …" com a data e o anel de feitas) e
    // `PainelDoDia.header(_:)` — que é quem o contém — deixou de ser chamado.
    // Um caso sem sujeito não é um caso; ⌘J continua provado por
    // `commandJTogglesTheDrawer`, logo abaixo.
    //
    // **A porta do painel para a gaveta é um achado para quem cuida do
    // Painel**, não um conserto desta tarefa: está no relatório.

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
        // **A linha do cabeçalho sai do bitmap.** O ✦ do cabeçalho da gaveta
        // é a primeira tinta de acento dentro dela, e o centro dele é a linha
        // em que os dois botões moram. Uma coordenada escrita à mão passaria a
        // mentir no primeiro ajuste de folga.
        let colunaDoSparkle = Self.drawerX + Int(MesaMetrics.drawerHeaderPadding.leading)
        let sparkle = try #require(
            centro(
                rep, de: theme.accentInk,
                x: colunaDoSparkle..<(Self.drawerX + 40),
                y: 0..<80, tol: 0.10, minimo: 20
            ),
            "não achei o ✦ do cabeçalho da gaveta"
        )

        // E os dois botões saem das medidas do desenho: `padding: 16px 18px
        // 10px`, ícones de 14 com `gap: 8`. O ✕ encosta na borda; o ↗ vem
        // antes.
        let recuo = Double(MesaMetrics.drawerHeaderPadding.trailing)
        let icone = Double(MesaMetrics.drawerActionGlyph)
        let fechar = 1_440 - recuo - icone / 2
        let destacar = fechar - icone - Double(MesaMetrics.headerGap)

        CliqueDeEnsaio.em(
            tela(store, session: session), size: Self.size,
            aY: sparkle.y, x: destacar
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

        // **A inclinação, e não a distância até uma cor escolhida a dedo.**
        //
        // Esmaecer a 45% é uma reta: `esmaecido = 0,45 · cheio + 0,55 · fundo`,
        // canal a canal. A régua antiga media a distância até `paper` e
        // supunha que o fundo fosse ele — no shell novo o conteúdo mora sobre
        // um painel, e a suposição passou a mentir (dava 0,35). A inclinação
        // da reta é a opacidade **seja qual for o fundo**, e é o que este caso
        // mede agora: nada de escolher a cor de referência.
        func amostras(_ session: AssistantSession) throws -> [Double] {
            let rep = try #require(Render.bitmap(
                tela(store, session: session), size: Self.size, theme: theme
            ))
            var canais: [Double] = []
            for px in stride(from: 420, to: Self.drawerX, by: 3) {
                for py in stride(from: 120, to: 300, by: 3) {
                    guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else {
                        continue
                    }
                    canais.append(c.redComponent)
                    canais.append(c.greenComponent)
                    canais.append(c.blueComponent)
                }
            }
            return canais
        }

        let cheia = try amostras(AssistantSession())
        let esmaecida = try amostras(AssistantSession(debugOpen: true))
        #expect(cheia.count == esmaecida.count)
        #expect(cheia.count > 300, "não havia conteúdo para esmaecer")

        let mediaC = cheia.reduce(0, +) / Double(cheia.count)
        let mediaE = esmaecida.reduce(0, +) / Double(esmaecida.count)
        var cov = 0.0
        var varC = 0.0
        for (c, e) in zip(cheia, esmaecida) {
            cov += (c - mediaC) * (e - mediaE)
            varC += (c - mediaC) * (c - mediaC)
        }
        #expect(varC > 0.01, "a coluna atrás da gaveta era de uma cor só")
        let opacidade = cov / varC
        #expect(
            abs(opacidade - AssistantDrawerMetrics.backdropOpacity) < 0.06,
            "o fundo ficou a \(opacidade) em vez de 0,45"
        )
    }
}

import AppKit
import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// O painel do dia (design 11), com a caixa do dono.
///
/// Um render para conferir com os olhos, e as duas decisões que a tela toma
/// sozinha: aceitar o plano cria compromissos, e o azulejo do rascunho abre o
/// cartão — **sem** enviar nada por conta própria.
@Suite("Painel do dia")
@MainActor
struct PainelDoDiaTests {

    private static let size = CGSize(width: 1_440, height: 852)

    private func inertConversation() -> AssistantConversation {
        AssistantConversation(
            scope: .email,
            context: .init(subject: "Caixa e agenda de hoje"),
            destination: .init(label: "Codex · ChatGPT", detail: "", isLocal: false),
            engine: AssistantEngine(supportsDraftReply: false) { _ in "" }
        )
    }

    private func tela(_ store: MailStore) -> some View {
        PainelDoDia(
            store: store,
            now: DiaDoDono.agoraMinuto,
            today: DiaDoDono.agora,
            drafts: DiaDoDono.rascunhos,
            conversation: inertConversation()
        )
        .environment(ThemeStore())
        .environment(ActionReceipts())
    }

    /// A tela da captura dele: 21h40, seis azulejos, zero prontas.
    private func telaDaNoite(
        _ store: MailStore,
        presentation: IntelligencePresentation = .onThisMac,
        optIn: Bool = false
    ) -> some View {
        PainelDoDia(
            store: store,
            now: DiaDoDono.noiteMinuto,
            today: DiaDoDono.noite,
            drafts: [:],
            conversation: inertConversation(),
            intelligencePresentation: presentation,
            automaticAnalysisOn: optIn
        )
        .environment(ThemeStore())
        .environment(ActionReceipts())
    }

    private func modeloDaNoite(
        _ store: MailStore,
        motivo: PainelDoDiaModelo.MotivoSemProntas = .aindaNaoEscreveu
    ) -> PainelDoDiaModelo {
        let plan = DashboardPlanInput.plan(
            store: store, drafts: [:], filter: .standard,
            today: DiaDoDono.noite, nowMinute: DiaDoDono.noiteMinuto
        )
        return PainelDoDiaModelo(
            plan: plan, drafts: [:], pending: store.pendingItems,
            agenda: store.agenda, messages: store.messages,
            today: DiaDoDono.noite, nowMinute: DiaDoDono.noiteMinuto,
            myAddresses: Set(store.accounts.map(\.address)),
            motivoSemProntas: motivo
        )
    }

    // MARK: - Os defeitos da captura

    /// Defeito 1: a grade cresce, nada rola, e a barra de estado some.
    @Test("com doze azulejos a barra de estado continua colada no pé")
    func theStatusBarSurvivesALongDay() async throws {
        let store = await DiaDoDono.lojaDaNoite()
        // Doze azulejos entre as duas colunas: o recorte da Caixa entrega sete
        // pessoas esperando, e as promessas do dono põem o resto.
        let cheia = await DiaDoDono.lojaDaNoite(
            mensagens: DiaDoDono.seisAzulejos + (1...6).map { DiaDoDono.extra($0) },
            pendentes: (1...6).map { DiaDoDono.promessaExtra($0) }
        )
        let modelo = modeloDaNoite(cheia)
        #expect(
            modelo.espera.count + modelo.promessas.count >= 12,
            "a fixture não encheu as colunas"
        )

        let rep = try #require(
            Render.bitmap(telaDaNoite(cheia), size: Self.size, theme: .okami)
        )
        // A barra é `surface2` no rodapé de 44 pt. Se ela tivesse sido empurrada
        // para fora, a faixa de baixo seria `paper` ou azulejo.
        let rodape = rep.pixels(
            matching: Theme.okami.surface2, tolerance: 0.02, y: 812..<851
        )
        #expect(rodape > 20_000, "a barra de estado saiu da janela")
        // E a tela curta continua com a mesma barra: rolar não a inventou.
        let curta = try #require(
            Render.bitmap(telaDaNoite(store), size: Self.size, theme: .okami)
        )
        #expect(curta.pixels(matching: Theme.okami.surface2, tolerance: 0.02,
                             y: 812..<851) > 20_000)
    }

    /// Defeito 3: o dia ia das 9 às 19, e eram 21h40 — e o conserto de então,
    /// uma janela que se alargava, virou o defeito seguinte: tudo encolhido.
    @Test("o eixo cobre da 01 h às 23h30 na densidade fixa, sem espremer nada")
    func theAxisCoversHisWholeNight() async throws {
        let modelo = modeloDaNoite(await DiaDoDono.lojaDaNoite())
        // Os três compromissos do dia estão na trilha da agenda, cada um no
        // seu lugar — inclusive o das 01 h, que o eixo antigo grudava na borda.
        let daAgenda = modelo.blocos.filter { $0.trilha == .agenda }
        #expect(daAgenda.map(\.startMinute).sorted() == [60, 570, 1_410])
        // E cada um cai numa posição própria do eixo de 3312 pt: a madrugada a
        // 138 pt da meia-noite, o voo a 3243, o agora das 21h40 no meio.
        #expect(PlanoDoDia.x(60) == 138)
        #expect(PlanoDoDia.x(1_410) == 3_243)
        #expect(PlanoDoDia.x(DiaDoDono.noiteMinuto) < PlanoDoDia.larguraDoEixo)
    }

    /// Defeito 6: tudo era "LEAD NOVO", e a newsletter era "ESPERANDO".
    @Test("as etiquetas da captura: só a Maria é lead novo")
    func onlyOneOfThemIsActuallyALead() async throws {
        let modelo = modeloDaNoite(await DiaDoDono.lojaDaNoite())
        let porID = Dictionary(uniqueKeysWithValues: modelo.espera.map { ($0.id, $0) })

        #expect(porID["maria"]?.palavra == "lead novo")
        // O "Re:" da Cats9th, o pedido do Jayden e o formulário do próprio
        // dono não são lead nenhum.
        #expect(porID["cats9th"]?.palavra == "esperando")
        // O Jayden tem prazo hoje: é a etiqueta que vence todas, e ela é a
        // única que acaba.
        #expect(porID["jayden"]?.palavra == "prazo hoje")
        #expect(porID["formulario"]?.palavra == "esperando")
        // Máquina não vira azulejo.
        #expect(porID["resend"] == nil)
        #expect(porID["carol"] == nil)
        #expect(porID["abacus"] == nil)
        #expect(modelo.espera.count == 6, "a captura tinha seis azulejos")
    }

    /// Defeito 7: "parece que a IA não tá fazendo porra nenhuma".
    @Test("com zero prontas o cabeçalho diz o motivo, e não só que não há")
    func theHeaderSaysWhyThereAreNoDrafts() async throws {
        let store = await DiaDoDono.lojaDaNoite()

        // Rota remota configurada, opt-in desligado: é o portão que barra.
        let barrado = modeloDaNoite(store, motivo: .precisaDoOptIn(destino: "Codex"))
        #expect(barrado.legendaDaEspera.contains("análise automática"))
        #expect(barrado.legendaDaEspera.contains("Codex"))
        #expect(barrado.legendaDaEspera.contains("Ativar"))

        // Motor fora do ar: outra frase, outra porta.
        let fora = modeloDaNoite(store, motivo: .motorIndisponivel(destino: "Codex"))
        #expect(fora.legendaDaEspera == "Codex indisponível · Entrar")

        // E nunca a frase muda de "nenhuma resposta pronta" e ponto.
        for modelo in [barrado, fora, modeloDaNoite(store)] {
            #expect(modelo.legendaDaEspera != "nenhuma resposta pronta")
            #expect(modelo.motivoSemProntas != nil)
        }

        // As promessas vazias dizem o que ainda não é lido, em vez de "0".
        #expect(modeloDaNoite(store).legendaDosCompromissos
            == "lido dos seus enviados · na próxima versão")
    }

    /// Ruling 2026-09-03: com um provedor remoto conectado, a rota já é a dele.
    /// A legenda que pedia "· Ativar" era burocracia em cima de um "sim" já
    /// dado, e some.
    @Test("com a rota no provedor o painel não pede para ativar nada")
    func noActivationLegendWhenTheRouteIsTheProvider() async throws {
        let store = await DiaDoDono.lojaDaNoite()
        let motivo = PainelDoDia.motivoSemProntas(
            destino: "Codex",
            motorDisponivel: true,
            rotaLocal: false,
            automaticAnalysisOn: true
        )
        let legenda = modeloDaNoite(store, motivo: motivo).legendaDaEspera
        #expect(!legenda.contains("Ativar"))
        #expect(!legenda.contains("análise automática"))
    }

    /// Defeito 7, a outra metade: "Nenhum prazo no radar" só é verdade quando
    /// o `MessageTriage.deadline` do foco de fato foi lido.
    @Test("os prazos do radar saem do MessageTriage.deadline das mensagens")
    func theDeadlineRadarActuallyReadsTheTriage() async throws {
        let modelo = modeloDaNoite(await DiaDoDono.lojaDaNoite())
        // O Jayden tem prazo hoje, a Abacus tem prazo sábado: os dois estão lá.
        #expect(modelo.dinheiro.contains { $0.id == "jayden" })
        #expect(modelo.dinheiro.contains { $0.id == "abacus" })
        #expect(modelo.dinheiro.contains { $0.valor == "6.000 créditos" })
        // E o bloco de prazo do dia entra na linha do tempo.
        #expect(modelo.blocos.contains { $0.tipo == .prazo })

        // Numa caixa sem nenhum prazo, aí sim o radar fica vazio — e é a
        // ausência de `deadline` que o esvazia, não uma leitura que não houve.
        let semPrazo = await DiaDoDono.lojaDaNoite(mensagens: [DiaDoDono.jack])
        #expect(modeloDaNoite(semPrazo).dinheiro.isEmpty)
    }

    /// A noite dele com nomes de verdade nos blocos: o teste que se olha para
    /// responder "dá para saber o que está agendado sem clicar?".
    @Test("o plano da noite desenha os nomes, e não chips de hora")
    func hisPlanShowsNames() async throws {
        let store = await DiaDoDono.lojaDaNoite(agenda: [
            AgendaItem(
                id: "luna", title: "Luna · Dev time weekly",
                startMinute: 60, endMinute: 120, accountID: "gmail"
            ),
            AgendaItem(
                id: "odette", title: "Termin de Odette",
                startMinute: 570, endMinute: 600, accountID: "gmail"
            ),
            AgendaItem(
                id: "aitherion", title: "Aitherion Labs · Estratégia Econômica",
                startMinute: 1_410, endMinute: 1_440, accountID: "vantion"
            ),
        ])
        let rep = try #require(Render.snapshot(
            telaDaNoite(store), named: "plano", size: Self.size, theme: .okami
        ))
        #expect(rep.pixelsWide == 1_440)
    }

    @Test("o painel da noite dele desenha em okami")
    func hisNightRendersInOkami() async throws {
        let store = await DiaDoDono.lojaDaNoite()
        let rep = try #require(Render.snapshot(
            telaDaNoite(store), named: "fix", size: Self.size, theme: .okami
        ))
        #expect(rep.pixelsWide == 1_440)
        #expect(rep.pixelsHigh == 852)
    }

    @Test("o painel desenha em okami")
    func rendersInOkami() async throws {
        let store = await DiaDoDono.loja()
        let rep = try #require(Render.snapshot(
            tela(store), named: "painel", size: Self.size, theme: .okami
        ))
        #expect(rep.pixelsWide == 1_440)
        #expect(rep.pixelsHigh == 852)
        #expect(
            rep.pixels(matching: Theme.okami.paper, tolerance: 0.01) > 100_000,
            "o painel perdeu o fundo paper"
        )
    }

    @Test("o modelo escreve o painel a partir do dia do dono")
    func theModelReadsTheOwnersDay() async throws {
        let store = await DiaDoDono.loja()
        let plan = DashboardPlanInput.plan(
            store: store, drafts: DiaDoDono.rascunhos, filter: .standard,
            today: DiaDoDono.agora, nowMinute: DiaDoDono.agoraMinuto
        )
        let modelo = PainelDoDiaModelo(
            plan: plan,
            drafts: DashboardPlanInput.validatedDrafts(DiaDoDono.rascunhos) {
                store.message($0)
            },
            pending: store.pendingItems,
            agenda: store.agenda,
            messages: store.messages,
            today: DiaDoDono.agora,
            nowMinute: DiaDoDono.agoraMinuto
        )
        // Máquina não espera você: a Abacus e a Resend ficam fora dos azulejos.
        #expect(!modelo.espera.contains { $0.id == "abacus" || $0.id == "resend" })
        // O Jayden tem prazo hoje e vem na frente do Jack, que espera há 7 dias.
        #expect(modelo.espera.first?.id == "jayden")
        #expect(modelo.espera.first?.palavra == "prazo hoje")
        #expect(modelo.espera.contains { $0.id == "jack" && $0.numero == "7" })
        // As duas promessas do dono, e as duas com bloco na linha do tempo.
        #expect(modelo.promessas.count == 2)
        #expect(modelo.propostos.count >= 2)
        // O valor só aparece onde o texto o afirma: os créditos da Abacus.
        #expect(modelo.dinheiro.contains { $0.valor == "6.000 créditos" })
    }

    @Test("Aceitar o plano cria os blocos propostos como compromissos")
    func acceptingThePlanCreatesTheEvents() async throws {
        let store = await DiaDoDono.loja()
        let antes = store.agenda.count
        let rep = try #require(Render.bitmap(tela(store), size: Self.size, theme: .tinta))
        // O botão primário do topo é o único bloco sólido de accent na faixa
        // do "Plano de hoje".
        let alvo = try #require(
            centro(de: Theme.tinta.accent, em: rep, x: 900..<1_300, y: 60..<110),
            "não achei o Aceitar o plano"
        )
        CliqueDeEnsaio.em(tela(store), size: Self.size, aY: alvo.y, x: alvo.x)
        #expect(store.agenda.count > antes, "Aceitar o plano não criou compromisso nenhum")
    }

    /// A régua de sempre: onde está o aglomerado desta cor no recorte dado.
    private func centro(
        de token: TokenColor, em rep: NSBitmapImageRep,
        x: Range<Int>, y: Range<Int>, tolerance: Double = 0.06
    ) -> CGPoint? {
        guard let alvo = token.nsColor.usingColorSpace(.sRGB) else { return nil }
        var somaX = 0, somaY = 0, n = 0
        for py in y where py < rep.pixelsHigh {
            for px in x where px < rep.pixelsWide {
                guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - alvo.redComponent) < tolerance,
                   abs(c.greenComponent - alvo.greenComponent) < tolerance,
                   abs(c.blueComponent - alvo.blueComponent) < tolerance {
                    somaX += px; somaY += py; n += 1
                }
            }
        }
        guard n > 8 else { return nil }
        return CGPoint(x: Double(somaX) / Double(n), y: Double(somaY) / Double(n))
    }
}

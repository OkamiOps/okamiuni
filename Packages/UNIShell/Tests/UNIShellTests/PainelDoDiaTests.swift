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

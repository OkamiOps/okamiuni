import Foundation
import Testing
import UNICore
import UNISync
@testable import UNIShell

/// A barra fina do chrome deixou de falar só de sincronização.
///
/// Tudo o que segura o dono esperando — a IA pensando, a fila de análise
/// trabalhando, o acervo sendo analisado, o corpo do email chegando — soma
/// num estado só, e é este tipo puro que faz a soma. A `View` não decide
/// nada disto.
@Suite("Barra de trabalho do chrome")
struct ChromeWorkloadTests {

    private let codex = AssistantDestination(
        label: "Codex · ChatGPT", detail: "Sai deste Mac.", isLocal: false
    )

    @Test("sem trabalho nenhum, a barra continua sendo a da sincronização")
    func idleKeepsTheSyncStatus() {
        #expect(ChromeWorkload.combining([.sync(.ready)]).status == .ready)
        #expect(ChromeWorkload.combining([.sync(.ready)]).detail == nil)
        #expect(ChromeWorkload.combining([.sync(.empty)]).status == .empty)
        #expect(
            ChromeWorkload.combining([.sync(.failed("Sessão expirada"))]).status
                == .failed("Sessão expirada")
        )
    }

    @Test("a sincronização sozinha mantém a fração que ela já tinha")
    func syncKeepsItsOwnFraction() {
        let carga = ChromeWorkload.combining([.sync(.loading(fraction: 0.4))])
        #expect(carga.status == .loading(fraction: 0.4))
        #expect(carga.detail == "Sincronizando")
    }

    @Test("a IA pensando acende a barra mesmo com a caixa parada")
    func assistantAloneLightsTheBar() {
        let carga = ChromeWorkload.combining([
            .sync(.ready), .assistant(kind: .question, destination: codex),
        ])
        #expect(carga.status == .loading(fraction: nil))
        #expect(carga.detail == "Perguntando ao Codex · ChatGPT")
    }

    @Test("cada trabalho da IA tem a sua frase, e o Mac não vira provedor")
    func assistantLabelsNameTheWork() {
        func frase(_ kind: AssistantWorkKind, _ destino: AssistantDestination) -> String? {
            ChromeWorkload.combining([
                .sync(.ready), .assistant(kind: kind, destination: destino),
            ]).detail
        }
        #expect(frase(.draft, codex) == "Escrevendo o rascunho com Codex · ChatGPT")
        #expect(frase(.briefing, codex) == "Preparando o briefing com Codex · ChatGPT")
        #expect(frase(.question, .onThisMac) == "Perguntando neste Mac")
        #expect(frase(.draft, .onThisMac) == "Escrevendo o rascunho neste Mac")
    }

    @Test("o acervo usa fração de verdade, e conta em quantas está")
    func backlogReportsRealProgress() {
        let carga = ChromeWorkload.combining([
            .sync(.ready), .backlog(done: 23, total: 312),
        ])
        #expect(carga.status == .loading(fraction: 23.0 / 312.0))
        #expect(carga.detail == "Analisando 23 de 312")
    }

    @Test("acervo sem total não finge porcentagem")
    func backlogWithoutTotalPulses() {
        let carga = ChromeWorkload.combining([.sync(.ready), .backlog(done: 0, total: 0)])
        #expect(carga.status == .loading(fraction: nil))
    }

    @Test("duas coisas com fração não escolhem uma: a barra respira")
    func twoProgressesFallBackToThePulse() {
        let carga = ChromeWorkload.combining([
            .sync(.loading(fraction: 0.5)), .backlog(done: 23, total: 312),
        ])
        #expect(carga.status == .loading(fraction: nil))
        #expect(carga.detail == "Analisando 23 de 312 · Sincronizando")
    }

    @Test("o acervo mantém a fração quando a sincronização não tem uma")
    func backlogKeepsFractionAgainstAnIndeterminateSync() {
        let carga = ChromeWorkload.combining([
            .sync(.loading(fraction: nil)), .backlog(done: 1, total: 4),
        ])
        #expect(carga.status == .loading(fraction: 0.25))
    }

    @Test("nada se perde: sincronizar, analisar, perguntar e carregar somam numa frase")
    func everythingRunningIsNamedInOrder() {
        let carga = ChromeWorkload.combining([
            .sync(.loading(fraction: nil)),
            .body,
            .assistant(kind: .question, destination: codex),
            .analysisQueue,
            .backlog(done: 2, total: 9),
        ])
        #expect(carga.status.isBusy)
        #expect(
            carga.detail
                == "Analisando 2 de 9 · Analisando mensagens · Perguntando ao Codex · ChatGPT"
                + " · Carregando o email · Sincronizando"
        )
    }

    @Test("carregar o corpo sozinho já acende a barra")
    func bodyLoadingAloneLightsTheBar() {
        let carga = ChromeWorkload.combining([.sync(.empty), .body])
        #expect(carga.status == .loading(fraction: nil))
        #expect(carga.detail == "Carregando o email")
    }

    @Test("a falha da conta não apaga o trabalho que continua correndo")
    func workWinsOverAFailedAccount() {
        let carga = ChromeWorkload.combining([
            .sync(.failed("Sessão expirada")), .analysisQueue,
        ])
        #expect(carga.status == .loading(fraction: nil))
        #expect(carga.detail == "Analisando mensagens")
    }
}

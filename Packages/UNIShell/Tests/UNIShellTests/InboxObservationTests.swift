import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// A dívida da Task 14, paga: o `MailStore` ganhou `observe()` e
/// `refreshBodyMatches()`, e **nenhuma tela os chamava**. Este teste é o que
/// impede a fiação de sumir de novo — ele falha com `load()` no lugar de
/// `observe()`, que é a única diferença entre a lista acordar sozinha e a
/// pessoa ficar olhando uma tela parada enquanto a conta baixa.
///
/// Fora da tela, como todo teste de interface deste projeto: a janela nasce a
/// 50.000pt de distância, não é trazida à frente e não recebe evento nenhum.
@Suite("A caixa de entrada assina a fonte")
@MainActor
struct InboxObservationTests {
    @Test("O segundo retrato chega à lista sem ninguém recarregar")
    func segundoRetratoChega() async throws {
        // Com o banco, o primeiro retrato é a conta recém-adicionada e vazia, e
        // as mensagens chegam nos retratos seguintes, enquanto a carga baixa.
        // Uma tela que só puxa uma vez ficaria parada nesse primeiro retrato até
        // alguém reabrir o app — que é exatamente o defeito que este teste
        // impede de voltar.
        let store = MailStore(source: DoisRetratos())
        // A janela fica **viva** enquanto o teste espera. `Render.bitmap`
        // fecharia a janela ao devolver o bitmap, e uma hierarquia derrubada
        // cancela o `.task` que assinava a fonte junto — o segundo retrato
        // chegaria ou não conforme a máquina estivesse ocupada, que é como um
        // teste vira sorteio.
        let janela = janelaViva(InboxScreen(store: store).environment(ThemeStore()))
        defer { janela.close() }
        // O segundo retrato sai 50ms depois do primeiro; o teto é folgado de
        // propósito, e o que se afere é o efeito, não o relógio.
        try await esperaAte { store.messages.count == Fixtures.messages.count }
        #expect(store.messages.count == Fixtures.messages.count)
    }

    // **Não há teste para a chamada irmã, `refreshBodyMatches()`, e o motivo
    // fica escrito.** Ela dispara no `onChange(of: query)`, e o único jeito de
    // mudar `query` de fora é `store.reveal(_:)`, que chega lá por duas
    // reavaliações de corpo em cadeia. Numa janela fora da tela, disputando o
    // ator principal com dezenas de renderizações, essas reavaliações acontecem
    // ou não conforme a carga da máquina: o teste passou sozinho, passou numa
    // rodada da suíte inteira e falhou na seguinte, sem uma linha mudar. Um
    // teste assim não prova a fiação — ele sorteia. O que sobrou no lugar:
    // `MailStore.refreshBodyMatches()` tem os testes dele em `UNICore`
    // (`MailStoreObservationTests`), a fonte do banco tem os dela em
    // `DatabaseMailSourceTests`, e a linha que as liga está na `InboxScreen`,
    // ao lado do `observe()` que o teste acima prende.

    /// Uma janela fora da área visível, **aberta**, com a hierarquia montada.
    ///
    /// Fora da tela pelos mesmos 50.000pt do `Render.bitmap`, e pelo mesmo
    /// motivo: verificar interface não pode roubar o computador de quem está
    /// usando. Ela não é trazida à frente, não vira janela-chave e não recebe
    /// evento nenhum — só desenha, e fica viva enquanto o teste espera.
    private func janelaViva<V: View>(_ view: V) -> NSWindow {
        let janela = NSWindow(
            contentRect: NSRect(x: -50_000, y: -50_000, width: 1440, height: 916),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        janela.isReleasedWhenClosed = false
        janela.contentView = NSHostingView(
            rootView: view
                .theme(.tinta)
                .environment(\.locale, Locale(identifier: "pt_BR"))
                .frame(width: 1440, height: 916)
        )
        janela.contentView?.layoutSubtreeIfNeeded()
        return janela
    }

    /// Espera por um efeito, com teto folgado.
    ///
    /// Trinta segundos porque a suíte roda em paralelo e o ator principal é
    /// disputado por dezenas de renderizações — o que se afere é o efeito, não
    /// o relógio, e um teto curto transformaria "a máquina estava ocupada" em
    /// "a fiação sumiu".
    private func esperaAte(
        segundos: Double = 30, _ condicao: @MainActor () -> Bool
    ) async throws {
        let fim = Date().addingTimeInterval(segundos)
        while Date() < fim, !condicao() {
            // `Task.sleep` e não `RunLoop.run`: quem entrega o `.task` da
            // `View` é o executor do ator principal, e girar o runloop de
            // dentro de um método síncrono do ator o mantém **ocupado** — a
            // espera ficava esperando um efeito que não tinha como acontecer.
            // Dormir devolve o ator.
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Uma fonte que entrega **dois** retratos: o primeiro sem mensagem nenhuma, o
/// segundo com as sete. Só chega ao segundo quem assina.
private struct DoisRetratos: MailSource {
    func accounts() async throws -> [Account] { Fixtures.accounts }
    func messages() async throws -> [Message] { [] }
    func agenda() async throws -> [AgendaItem] { [] }
    func pendingItems() async throws -> [PendingItem] { [] }

    func snapshots() -> AsyncThrowingStream<MailSnapshot, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                MailSnapshot(accounts: Fixtures.accounts, messages: [], agenda: [], pendingItems: [])
            )
            let tarefa = Task {
                try? await Task.sleep(for: .milliseconds(50))
                continuation.yield(
                    MailSnapshot(
                        accounts: Fixtures.accounts, messages: Fixtures.messages,
                        agenda: [], pendingItems: []
                    )
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in tarefa.cancel() }
        }
    }
}

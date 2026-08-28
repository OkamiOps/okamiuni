import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// A dívida da Task 14, paga e presa: o `MailStore` ganhou `observe()` e
/// `refreshBodyMatches()`, e **nenhuma tela os chamava**.
///
/// Nada aqui renderiza, abre janela ou espera relógio. A primeira versão destes
/// testes fazia as três coisas — montava a tela numa janela fora do ar e
/// esperava o efeito com teto de tempo — e era sorteada pela carga da máquina:
/// verde sozinha, verde numa rodada da suíte inteira, vermelha na seguinte, sem
/// uma linha mudar. O que os deixou determinísticos foi tirar o tempo da
/// equação: os corpos do `.task` e do `onChange` da busca moram em métodos da
/// `InboxScreen` (`subscribeToSource()` e `searchChanged(to:)`), e o teste os
/// chama e **aguarda**. O duplo de fonte conta quem pediu o quê.
@Suite("A caixa de entrada assina a fonte")
@MainActor
struct InboxObservationTests {
    @Test("A tela **assina** a fonte, em vez de puxar um retrato só")
    func telaAssinaAFonte() async throws {
        // A distinção é a diferença entre a lista acordar sozinha enquanto a
        // conta baixa e a pessoa ficar olhando uma tela parada: `load()` pede
        // um retrato (`snapshot()`), `observe()` assina (`snapshots()`).
        let fonte = FonteQueConta()
        let store = MailStore(source: fonte)
        await InboxScreen(store: store).subscribeToSource()

        #expect(fonte.assinaturas == 1)
        #expect(fonte.retratosAvulsos == 0)
        // E o que a assinatura entregou chegou à lista.
        #expect(store.messages.map(\.id) == Fixtures.messages.map(\.id))
    }

    @Test("Mudar a busca pergunta o corpo à fonte, com o termo")
    func buscaAlcancaOCorpo() async throws {
        let fonte = FonteQueConta()
        let store = MailStore(source: fonte)
        let tela = InboxScreen(store: store)
        await tela.subscribeToSource()

        await tela.searchChanged(to: "Revisão")

        #expect(store.query == "Revisão")
        #expect(fonte.termosBuscados == ["Revisão"])
    }

    @Test("Busca vazia não vai à fonte — consultar o índice com nada devolveria a caixa inteira")
    func buscaVaziaNaoConsulta() async throws {
        let fonte = FonteQueConta()
        let store = MailStore(source: fonte)
        let tela = InboxScreen(store: store)
        await tela.subscribeToSource()

        await tela.searchChanged(to: "   ")

        #expect(fonte.termosBuscados.isEmpty)
    }
}

/// Uma fonte que anota **o que lhe pediram**: quantas assinaturas, quantos
/// retratos avulsos, e com que termos a busca no corpo foi consultada.
///
/// `@unchecked Sendable` com trava porque `MailSource` é `Sendable` e as
/// anotações são escritas de dentro de métodos assíncronos.
private final class FonteQueConta: MailSource, @unchecked Sendable {
    private let trava = NSLock()
    private var _assinaturas = 0
    private var _retratosAvulsos = 0
    private var _termos: [String] = []

    var assinaturas: Int { lendo { _assinaturas } }
    var retratosAvulsos: Int { lendo { _retratosAvulsos } }
    var termosBuscados: [String] { lendo { _termos } }

    func accounts() async throws -> [Account] { Fixtures.accounts }
    func messages() async throws -> [Message] { Fixtures.messages }
    func agenda() async throws -> [AgendaItem] { [] }
    func pendingItems() async throws -> [PendingItem] { [] }

    /// O caminho do `load()`. Contado para o teste poder afirmar que a tela
    /// **não** o tomou.
    func snapshot() async throws -> MailSnapshot {
        anota { _retratosAvulsos += 1 }
        return retrato
    }

    /// O caminho do `observe()`. Um retrato e termina — como toda fonte que não
    /// observa de verdade —, o que mantém o teste sem relógio.
    func snapshots() -> AsyncThrowingStream<MailSnapshot, any Error> {
        anota { _assinaturas += 1 }
        let valor = retrato
        return AsyncThrowingStream { continuation in
            continuation.yield(valor)
            continuation.finish()
        }
    }

    func bodyMatches(_ term: String, accountID: String?) async throws -> Set<String>? {
        anota { _termos.append(term) }
        return []
    }

    private var retrato: MailSnapshot {
        MailSnapshot(
            accounts: Fixtures.accounts, messages: Fixtures.messages,
            agenda: [], pendingItems: []
        )
    }

    private func anota(_ bloco: () -> Void) {
        trava.lock()
        defer { trava.unlock() }
        bloco()
    }

    private func lendo<T>(_ bloco: () -> T) -> T {
        trava.lock()
        defer { trava.unlock() }
        return bloco()
    }
}

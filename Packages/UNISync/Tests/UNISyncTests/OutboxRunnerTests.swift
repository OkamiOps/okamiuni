import Foundation
import GRDB
import NIOPosix
import Testing
@testable import UNICore
@testable import UNISync

@Suite("A fila segue as contas")
struct OutboxRunnerTests {
    private let conta = Account(
        id: "conta-nova", address: "eu@meudominio.com.br", displayName: "Meu",
        provider: .imap, host: "meudominio",
        tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7", signature: "Eu",
        imap: ImapEndpoint(host: "imap.meudominio.com.br", port: 993, security: .tls),
        state: .ativa
    )

    @Test("A conta adicionada com o app aberto ganha executor sem reiniciar")
    func contaNovaGanhaExecutor() async throws {
        let banco = try SyncDatabase.temporary()
        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { grupo.shutdownGracefully { _ in } }
        let runner = OutboxRunner(
            database: banco, secrets: InMemorySecretStore(), auth: nil,
            session: .shared, eventLoopGroup: grupo, signal: OutboxSignal()
        )

        // A abertura do app: a fila liga com o banco vazio.
        await runner.start()
        #expect(await runner.executor(for: conta.id) == nil)

        // A pessoa adiciona uma conta com o app aberto…
        try await banco.pool.write { db in
            try AccountRecord(conta, createdAt: Date(timeIntervalSince1970: 1)).insert(db)
        }
        // …e o diretor publica a lista nova. Sem `follow`, era aqui que a
        // fila ficava surda: a conta nunca ganhava executor e toda ação dela
        // dormia como `pendente`, com zero tentativas — o defeito real do
        // Gmail do dono.
        let (fluxo, publicacao) = AsyncStream.makeStream(of: [AccountStatus].self)
        await runner.follow(fluxo)
        publicacao.yield([])

        var ganhou = false
        for _ in 0..<200 where !ganhou {
            ganhou = await runner.executor(for: conta.id) != nil
            if !ganhou { try await Task.sleep(for: .milliseconds(10)) }
        }
        publicacao.finish()
        await runner.stop()
        #expect(ganhou, "a publicação do diretor devia religar a fila")
    }
}

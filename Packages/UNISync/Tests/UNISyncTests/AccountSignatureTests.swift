import Foundation
import GRDB
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

private func encerraGrupoDeAssinatura(_ grupo: MultiThreadedEventLoopGroup) {
    grupo.shutdownGracefully { _ in }
}

@Suite("Assinatura por conta", .serialized)
struct AccountSignatureTests {
    private let criadaEm = Date(timeIntervalSince1970: 1_800_000_000)

    private func conta() -> Account {
        Account(
            id: "conta-assinatura", address: "eu@exemplo.com",
            displayName: "Trabalho", provider: .imap, host: "exemplo",
            tintLightHex: "#725B9A", tintDarkHex: "#C2A7F4",
            signature: "Assinatura antiga", imap: ImapEndpoint(
                host: "imap.exemplo.com", port: 993, security: .tls
            ), state: .erroDeAutenticacao, lastSyncedAt: criadaEm
        )
    }

    private func diretor(_ db: SyncDatabase, grupo: MultiThreadedEventLoopGroup) -> AccountDirector {
        AccountDirector(
            database: db, secrets: InMemorySecretStore(), auth: nil,
            session: StubURLProtocol.session(),
            eventLoopGroup: grupo,
            imapConnect: { _, _ in throw SyncError.rede("não usado neste teste") },
            now: { self.criadaEm }
        )
    }

    @Test("A assinatura atualizada preserva todos os demais campos do registro")
    func atualizaSemPerderHistoria() async throws {
        let db = try SyncDatabase.temporary()
        let original = conta()
        try await db.pool.write {
            try AccountRecord(original, createdAt: self.criadaEm).insert($0)
        }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerraGrupoDeAssinatura(grupo) }
        let director = diretor(db, grupo: grupo)

        let atualizada = try await director.updateSignature(
            accountID: original.id, signature: "Marcos\nAitherion Labs"
        )
        #expect(atualizada.signature == "Marcos\nAitherion Labs")

        let registro = try await db.pool.read { connection in
            let fetched = try AccountRecord.fetchOne(connection, key: original.id)
            return try #require(fetched)
        }
        #expect(registro.signature == "Marcos\nAitherion Labs")
        #expect(registro.id == original.id)
        #expect(registro.address == original.address)
        #expect(registro.displayName == original.displayName)
        #expect(registro.provider == original.provider.rawValue)
        #expect(registro.host == original.host)
        #expect(registro.tintLightHex == original.tintLightHex)
        #expect(registro.tintDarkHex == original.tintDarkHex)
        #expect(registro.imapHost == original.imap?.host)
        #expect(registro.imapPort == original.imap?.port)
        #expect(registro.imapSecurity == original.imap?.security.rawValue)
        #expect(registro.state == original.state.rawValue)
        #expect(registro.lastSyncedAt == original.lastSyncedAt)
        #expect(registro.createdAt == criadaEm)
    }

    @Test("O retrato publicado carrega a assinatura e o modelo repassa erro/sucesso")
    @MainActor
    func publicaNoStatusEPassaPeloModelo() async throws {
        let db = try SyncDatabase.temporary()
        let original = conta()
        try await db.pool.write {
            try AccountRecord(original, createdAt: self.criadaEm).insert($0)
        }

        let grupo = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { encerraGrupoDeAssinatura(grupo) }
        let director = diretor(db, grupo: grupo)
        let modelo = AccountsModel(director: director)
        let observador = Task { @MainActor in await modelo.start() }
        defer { observador.cancel() }

        try await espera(
            prazo: .seconds(3),
            enquanto: { await modelo.statuses.first?.accountID != original.id }
        )
        #expect(modelo.statuses.first?.signature == original.signature)

        #expect(await modelo.updateSignature(
            accountID: original.id, signature: "Assinatura nova"
        ))
        try await espera(
            prazo: .seconds(3),
            enquanto: { await modelo.statuses.first?.signature != "Assinatura nova" }
        )
        #expect(modelo.statuses.first?.signature == "Assinatura nova")
        #expect(modelo.lastError == nil)

        #expect(await modelo.updateSignature(
            accountID: "conta-inexistente", signature: "não grava"
        ) == false)
        #expect(modelo.lastError == .resposta("A conta não existe."))
    }

    @Test("Conta sem assinatura continua com o default seguro vazio")
    func defaultVazio() {
        let status = AccountStatus(
            accountID: "conta", address: "conta@exemplo.com", hostMark: "exemplo",
            state: .ativa, messageCount: 0, lastSyncedAt: nil,
            error: nil, progress: nil
        )
        #expect(status.signature.isEmpty)
    }

    private func espera(
        prazo: Duration,
        enquanto condicao: @escaping @Sendable () async -> Bool
    ) async throws {
        let passo = Duration.milliseconds(20)
        var gasto = Duration.zero
        while await condicao(), gasto < prazo {
            try await Task.sleep(for: passo)
            gasto += passo
        }
        #expect(!(await condicao()), "A condição não mudou antes do prazo")
    }
}

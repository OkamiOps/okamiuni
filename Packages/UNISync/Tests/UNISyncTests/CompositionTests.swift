import Foundation
import Testing
import UNICore
@testable import UNISync

/// `@MainActor` porque `AppComposition.make` é do ator principal — ela cria o
/// apresentador da autorização do sistema e o diretor que a janela consome. O
/// teste roda onde o app compõe.
@Suite("A composição do app")
@MainActor
struct CompositionTests {
    @Test("Sem banco possível, o app cai nas fixtures em vez de não abrir")
    func semBancoCaiNasFixtures() {
        // Um caminho impossível é o pior caso realista (disco cheio, contêiner
        // corrompido). O app tem de abrir mostrando as fixtures e dizendo o
        // que houve, e não morrer na tela cinza.
        let composicao = AppComposition.make(
            databasePath: "/caminho/que/nao/existe/mail.sqlite", bundle: .main
        )
        #expect(composicao.database == nil)
        #expect(composicao.director == nil)
        #expect(composicao.configError != nil)
        #expect(composicao.source is InMemoryMailSource)
    }

    @Test("Com banco vazio, o que a fonte entrega continua sendo as fixtures")
    func bancoVazioContinuaNasFixtures() async throws {
        // É o estado antes da primeira conta. As capturas e os ensaios do
        // Marco 1 dependem disto: sem conta, o app é o do Marco 1.
        //
        // A afirmação é sobre o **retrato**, e não sobre o tipo da fonte, e a
        // diferença é a razão de a Task 18 divergir do plano aqui: o plano
        // escolhia `InMemoryMailSource` na abertura, o que amarraria a troca a
        // reiniciar o app. A fonte é sempre a do banco; quem devolve as
        // fixtures é ela, enquanto não houver conta. Ver
        // `DatabaseMailSource.emptyFallback` e o teste da troca ao vivo.
        let caminho = NSTemporaryDirectory() + "okamiuni-teste-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: caminho) }
        let composicao = AppComposition.make(databasePath: caminho, bundle: .main)
        #expect(composicao.database != nil)
        #expect(composicao.director != nil)

        let retrato = try await composicao.source.snapshot()
        let fixtures = try await InMemoryMailSource.fixtures.snapshot()
        #expect(retrato == fixtures)
        // E a busca no corpo diz "não sei procurar", que é o que mantém a busca
        // do Marco 1 valendo sobre as fixtures.
        #expect(try await composicao.source.bodyMatches("revisao", accountID: nil) == nil)
    }

    @Test("A primeira conta a entrar troca as fixtures pelo banco sem reiniciar")
    func trocaAoVivo() async throws {
        // O critério de aceite promete os dois sentidos da troca, e promete-os
        // no app aberto. Quem os cumpre é a observação: o `MailStore` assina
        // uma vez, no `observe()`, e o retrato seguinte já é o do banco.
        let caminho = NSTemporaryDirectory() + "okamiuni-teste-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: caminho) }
        let composicao = AppComposition.make(databasePath: caminho, bundle: .main)
        let banco = try #require(composicao.database)

        var retratos = composicao.source.snapshots().makeAsyncIterator()
        let primeiro = try #require(try await retratos.next())
        #expect(primeiro.accounts == Fixtures.accounts)

        try await banco.pool.write { conexao in
            try AccountRecord(
                Account(
                    id: "c", address: "eu@x.com", displayName: "Eu",
                    provider: .imap, host: "x",
                    tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
                ),
                createdAt: Date(timeIntervalSince1970: 1)
            ).insert(conexao)
        }

        let segundo = try #require(try await retratos.next())
        #expect(segundo.accounts.map(\.address) == ["eu@x.com"])
        #expect(segundo.messages.isEmpty)
    }

    @Test("Com uma conta no banco, a fonte passa a ser o banco")
    func comContaUsaOBanco() throws {
        let caminho = NSTemporaryDirectory() + "okamiuni-teste-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: caminho) }

        let db = try SyncDatabase(path: caminho)
        try db.pool.write { conexao in
            try AccountRecord(
                Account(
                    id: "c", address: "eu@x.com", displayName: "Eu",
                    provider: .imap, host: "x",
                    tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
                ),
                createdAt: Date(timeIntervalSince1970: 1)
            ).insert(conexao)
        }

        let composicao = AppComposition.make(databasePath: caminho, bundle: .main)
        #expect(composicao.source is DatabaseMailSource)
    }

    @Test("Sem client ID no bundle, o diretor existe e a rota IMAP continua inteira")
    func semClientIDNaoDerrubaOApp() throws {
        // O bundle de teste não tem OkamiUNIGoogleClientID.
        let caminho = NSTemporaryDirectory() + "okamiuni-teste-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: caminho) }
        let composicao = AppComposition.make(databasePath: caminho, bundle: .main)
        #expect(composicao.director != nil)
        // O erro de configuração é informado, e não fatal.
        #expect(composicao.configError == SyncError.semClientID)
    }
}

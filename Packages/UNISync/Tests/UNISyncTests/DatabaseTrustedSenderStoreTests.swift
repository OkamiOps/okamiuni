import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

/// A porta de confiança do disco: o outro lado da queixa "toda hora tenho que
/// clicar em Carregar, mesmo em remetente confiável".
///
/// A regra de normalização e a de "vale ou não vale" são provadas em `UNICore`
/// (`SenderTrustTests`). Aqui prova-se o disco: a tabela da v6 existe, o
/// endereço vai e volta, sobrevive a fechar e reabrir o banco, e é gravado
/// **sem conta cadastrada** — que é onde uma chave estrangeira para `account`
/// impediria a gravação.
@Suite("O remetente confiável no disco")
struct DatabaseTrustedSenderStoreTests {

    @Test("Confiar grava, e a lista volta normalizada")
    func gravaELe() throws {
        let store = DatabaseTrustedSenderStore(database: try SyncDatabase.temporary())
        #expect(try store.trustedSenders().isEmpty)

        try store.trustSender("NoReply@Calendly.com")
        #expect(try store.trustedSenders() == ["noreply@calendly.com"])

        // Confiar de novo é a mesma decisão, não uma segunda linha.
        try store.trustSender("noreply@calendly.com")
        #expect(try store.trustedSenders().count == 1)
    }

    @Test("A confiança sobrevive a fechar e reabrir o banco")
    func sobreviveAoReinicio() throws {
        let caminho = NSTemporaryDirectory() + "okamiuni-confianca-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: caminho) }

        // Sem conta nenhuma no banco — é o caso das fixtures, e a v6 não tem
        // chave estrangeira justamente para ele.
        try DatabaseTrustedSenderStore(database: try SyncDatabase(path: caminho))
            .trustSender("noreply@calendly.com")

        let depoisDoReinicio = DatabaseTrustedSenderStore(
            database: try SyncDatabase(path: caminho)
        )
        #expect(try depoisDoReinicio.trustedSenders() == ["noreply@calendly.com"])
    }

    @Test("Revogar tira do disco, e o reinício não a traz de volta")
    func revogar() throws {
        let caminho = NSTemporaryDirectory() + "okamiuni-confianca-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: caminho) }

        let store = DatabaseTrustedSenderStore(database: try SyncDatabase(path: caminho))
        try store.trustSender("noreply@calendly.com")
        try store.revokeSenderTrust("NOREPLY@CALENDLY.COM")
        #expect(try store.trustedSenders().isEmpty)

        let depois = DatabaseTrustedSenderStore(database: try SyncDatabase(path: caminho))
        #expect(try depois.trustedSenders().isEmpty)
    }

    @Test("Revogar quem nunca foi confiado não é erro")
    func revogarOInexistente() throws {
        let store = DatabaseTrustedSenderStore(database: try SyncDatabase.temporary())
        try store.revokeSenderTrust("ninguem@exemplo.com")
        #expect(try store.trustedSenders().isEmpty)
    }

    @Test("A tabela da v6 existe, e as cinco migrações anteriores continuam de pé")
    func migracaoV6() throws {
        let banco = try SyncDatabase.temporary()
        try banco.pool.read { db in
            #expect(try db.tableExists("trusted_sender"))
            // As tabelas das migrações anteriores, intactas.
            #expect(try db.tableExists("account"))
            #expect(try db.tableExists("message_body"))
            #expect(try db.tableExists("created_agenda_item"))
            let colunas = try db.columns(in: "trusted_sender").map(\.name)
            #expect(colunas == ["address", "createdAt"])
        }
    }

    @Test("A confiança não tem dono: apagar a conta não a leva junto")
    func naoDependeDaConta() throws {
        let banco = try SyncDatabase.temporary()
        try banco.pool.write { db in
            try AccountRecord(
                Account(
                    id: "c", address: "eu@x.com", displayName: "Eu",
                    provider: .imap, host: "x",
                    tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
                ),
                createdAt: Date(timeIntervalSince1970: 1)
            ).insert(db)
        }
        let store = DatabaseTrustedSenderStore(database: banco)
        try store.trustSender("noreply@calendly.com")

        _ = try banco.pool.write { db in try AccountRecord.deleteOne(db, key: "c") }
        #expect(try store.trustedSenders() == ["noreply@calendly.com"])
    }
}

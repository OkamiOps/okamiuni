import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

/// A descoberta das pastas do provedor: o que entra na tabela `folder`, o que
/// sai dela quando some do servidor, e o que nunca sai.
///
/// **Nada aqui toca rede**: `FolderSync` é banco puro, e os rótulos e pastas
/// entram como valores.
@Suite("As pastas do provedor")
struct FolderDiscoveryTests {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private func banco(provider: Account.Provider = .imap) async throws -> (SyncDatabase, Account) {
        let db = try SyncDatabase.temporary()
        let conta = Account(
            id: "c1", address: "marcos@okamiops.com", displayName: "Trabalho",
            provider: provider, host: "okamiops",
            tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9", state: .ativa
        )
        let carimbo = agora
        try await db.pool.write { try AccountRecord(conta, createdAt: carimbo).insert($0) }
        return (db, conta)
    }

    private func registros(_ nomes: [String], conta: String) -> [FolderRecord] {
        InitialLoader.registros(
            nomes.map { ImapFolder(name: $0, specialUse: nil) }, accountID: conta
        )
    }

    // MARK: Gravar

    @Test("Uma pasta do usuário vira linha, com o nome do provedor inteiro")
    func gravaAsPastas() async throws {
        let (db, conta) = try await banco()
        let lista = registros(["INBOX", "Clientes/Faturas"], conta: conta.id)
        try await db.pool.write { conexao in
            try FolderSync.reconcile(conexao, accountID: conta.id, discovered: lista)
        }

        let pastas = try await db.pool.read { conexao in
            try FolderRecord.fetchAll(conexao).compactMap(\.folder)
        }
        #expect(Set(pastas.map(\.displayName)) == ["INBOX", "Clientes/Faturas"])
        // O caminho composto é mostrado como veio — o mínimo honesto sobre
        // hierarquia, documentado em `MailFolder.serverName`.
        #expect(pastas.contains { $0.serverName == "Clientes/Faturas" })
        #expect(pastas.first { $0.serverName == "INBOX" }?.role == .inbox)
    }

    // MARK: Apagar

    /// **A mutação:** apagar o bloco de remoção de `FolderSync.reconcile` (ou
    /// trocá-lo por um `return 0`) deixa a pasta apagada no webmail para sempre
    /// na barra lateral, com as mensagens dela enchendo Arquivado.
    @Test("A pasta apagada no servidor some do banco — e as mensagens dela junto")
    func apagaAQueSumiu() async throws {
        let (db, conta) = try await banco()
        let antes = registros(["INBOX", "Antiga"], conta: conta.id)
        let idDaAntiga = FolderRecord.id(accountID: conta.id, serverName: "Antiga")
        let contaID = conta.id
        try await db.pool.write { conexao in
            try FolderSync.reconcile(conexao, accountID: contaID, discovered: antes)
            let mensagem = Message(
                id: "m-antiga", accountID: contaID,
                from: Contact(name: "Marina", address: "marina@x.com"),
                receivedAt: Date(timeIntervalSince1970: 1_799_000_000),
                subject: "Assunto", snippet: "Trecho", body: [], tags: [],
                bucket: .archived, isRead: false, summary: nil, detectedEvent: nil
            )
            try MessageRecord(mensagem, folderID: idDaAntiga).insert(conexao)
        }

        try await db.pool.write { conexao in
            try FolderSync.reconcile(
                conexao, accountID: contaID, discovered: self.registros(["INBOX"], conta: contaID)
            )
        }

        let (pastas, mensagens) = try await db.pool.read { conexao in
            (try FolderRecord.fetchCount(conexao), try MessageRecord.fetchCount(conexao))
        }
        #expect(pastas == 1)
        // A cascata da chave estrangeira: a mensagem que morava na pasta
        // apagada não pode ficar no banco sem pasta — ela apareceria em
        // Arquivado para sempre, sem nada no servidor que a explicasse.
        #expect(mensagens == 0)
    }

    /// **A mutação:** tirar a guarda `guard !discovered.isEmpty` faz um `LIST`
    /// que voltou vazio (soluço do servidor, resposta que o analisador não
    /// entendeu) apagar a caixa inteira da pessoa.
    @Test("Uma listagem vazia não apaga nada")
    func listagemVaziaNaoApaga() async throws {
        let (db, conta) = try await banco()
        let contaID = conta.id
        try await db.pool.write { conexao in
            try FolderSync.reconcile(
                conexao, accountID: contaID, discovered: self.registros(["INBOX"], conta: contaID)
            )
            try FolderSync.reconcile(conexao, accountID: contaID, discovered: [])
        }
        let quantas = try await db.pool.read { try FolderRecord.fetchCount($0) }
        #expect(quantas == 1)
    }

    /// **A mutação:** tirar `preservando` da chamada do Gmail apaga a
    /// pseudo-pasta — e com ela, por cascata, **todas** as mensagens da conta.
    @Test("A pseudo-pasta do Gmail sobrevive à reconciliação dos rótulos")
    func pseudoPastaSobrevive() async throws {
        let (db, conta) = try await banco(provider: .gmail)
        let pseudo = FolderRecord.gmail(accountID: conta.id)
        let rotulos = GmailFolders.records(
            [GmailLabel(id: "INBOX", name: "INBOX", type: "system")], accountID: conta.id
        )
        let contaID = conta.id
        try await db.pool.write { conexao in
            try pseudo.save(conexao)
            try FolderSync.reconcile(
                conexao, accountID: contaID, discovered: rotulos, preservando: [pseudo.id]
            )
        }
        let ids = try await db.pool.read { conexao in
            try FolderRecord.fetchAll(conexao).map(\.id)
        }
        #expect(ids.contains(pseudo.id))
    }

    /// A pseudo-pasta existe para a chave estrangeira, e não é um lugar: a
    /// barra lateral não pode desenhar uma linha "Gmail" com a conta inteira
    /// dentro, ao lado dos rótulos de verdade.
    @Test("A pseudo-pasta do Gmail não é uma pasta da barra lateral")
    func pseudoPastaNaoAparece() {
        #expect(FolderRecord.gmail(accountID: "c1").folder == nil)
    }
}

import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

@Suite("A fonte que lê do banco")
struct DatabaseMailSourceTests {
    private let conta = Account(
        id: "conta-a", address: "eu@x.com", displayName: "Eu",
        provider: .imap, host: "x", tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"
    )

    private func semeia(_ db: SyncDatabase, corpo: [String] = ["A revisão saiu."]) async throws {
        try await db.pool.write { conexao in
            try AccountRecord(self.conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "INBOX"
            ).insert(conexao)
            let mensagem = Message(
                id: "m1", accountID: "conta-a",
                from: Contact(name: "Marina", address: "marina@x.com"),
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
                subject: "Assunto", snippet: "Trecho", body: corpo,
                tags: [], bucket: .today, isRead: false,
                summary: nil, detectedEvent: nil, serverID: "9001", uidValidity: 42
            )
            try MessageRecord(mensagem, folderID: "conta-a/INBOX").insert(conexao)
            var registroDeCorpo = MessageBodyRecord(messageID: "m1", paragraphs: corpo)
            try registroDeCorpo.insert(conexao)
            try AgendaItemRecord(AgendaItem(
                id: "a1", title: "Reunião", startMinute: 570, endMinute: 600, accountID: "conta-a"
            )).insert(conexao)
        }
    }

    @Test("O snapshot traz contas, mensagens e agenda do banco")
    func snapshot() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db)
        let snapshot = try await DatabaseMailSource(database: db).snapshot()

        #expect(snapshot.accounts.map(\.id) == ["conta-a"])
        #expect(snapshot.messages.map(\.id) == ["m1"])
        #expect(snapshot.messages.first?.serverID == "9001")
        #expect(snapshot.agenda.map(\.id) == ["a1"])
        // `pendingItems` é do Marco 1 e não tem tabela: lista vazia, não erro.
        #expect(snapshot.pendingItems.isEmpty)
    }

    @Test("O corpo vem junto para quem já o tem no banco")
    func corpoNoSnapshot() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db)
        let snapshot = try await DatabaseMailSource(database: db).snapshot()
        #expect(snapshot.messages.first?.body == ["A revisão saiu."])
    }

    @Test("A busca de corpo desce para o índice e dobra acento")
    func buscaDeCorpo() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db)
        let fonte = DatabaseMailSource(database: db)
        #expect(try await fonte.bodyMatches("revisao", accountID: nil) == ["m1"])
        #expect(try await fonte.bodyMatches("orcamento", accountID: nil) == [])
        #expect(try await fonte.bodyMatches("revisao", accountID: "outra") == [])
    }

    @Test("A observação entrega o estado atual e acorda a cada escrita")
    func observacao() async throws {
        let db = try SyncDatabase.temporary()
        try await semeia(db)
        let fonte = DatabaseMailSource(database: db)

        var vistos: [Int] = []
        for try await snapshot in fonte.snapshots() {
            vistos.append(snapshot.messages.count)
            if vistos.count == 1 {
                try await db.pool.write { conexao in
                    let outra = Message(
                        id: "m2", accountID: "conta-a",
                        from: Contact(name: "Outro", address: "o@x.com"),
                        receivedAt: Date(timeIntervalSince1970: 1_800_000_100),
                        subject: "Novo", snippet: "Novo", body: [],
                        tags: [], bucket: .today, isRead: false,
                        summary: nil, detectedEvent: nil
                    )
                    try MessageRecord(outra, folderID: "conta-a/INBOX").insert(conexao)
                }
            }
            if vistos.count == 2 { break }
        }
        #expect(vistos == [1, 2])
    }

    @Test("Vinte lotes não viram vinte e um retratos: a observação coalesce")
    func observacaoCoalesce() async throws {
        // Medido antes do conserto: 20 lotes de 50 davam **21 disparos**, com
        // contagens 0, 50, 100 … 1000 — um retrato por lote, cada um refazendo
        // a tabela inteira, que estava crescendo. A 50 mil mensagens e lotes de
        // 50 isso é mil retratos e mais de 25 milhões de linhas materializadas,
        // uns 290 s de CPU só reconstruindo retratos durante a carga.
        //
        // MUTAÇÃO QUE ISTO PEGA: voltar o retrato caro para dentro da
        // `ValueObservation` (ou trocar `bufferingNewest(1)` por `.unbounded`)
        // faz os disparos voltarem a acompanhar os lotes um a um.
        let db = try SyncDatabase.temporary()
        try await db.pool.write { conexao in
            try AccountRecord(self.conta, createdAt: Date(timeIntervalSince1970: 1)).insert(conexao)
            try FolderRecord(
                id: "conta-a/INBOX", accountID: "conta-a",
                serverName: "INBOX", role: .inbox, displayName: "INBOX"
            ).insert(conexao)
        }
        let fonte = DatabaseMailSource(database: db)
        let lotes = 20
        let porLote = 50

        let vistos = Contagens()
        let consumo = Task {
            for try await snapshot in fonte.snapshots() {
                vistos.registra(snapshot.messages.count)
                if snapshot.messages.count >= lotes * porLote { break }
            }
        }

        for lote in 0..<lotes {
            try await db.pool.write { conexao in
                for indice in 0..<porLote {
                    let numero = lote * porLote + indice
                    let mensagem = Message(
                        id: "m\(numero)", accountID: "conta-a",
                        from: Contact(name: "Marina", address: "marina@x.com"),
                        receivedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(numero)),
                        subject: "Assunto", snippet: "Trecho", body: [],
                        tags: [], bucket: .today, isRead: false,
                        summary: nil, detectedEvent: nil
                    )
                    try MessageRecord(mensagem, folderID: "conta-a/INBOX").insert(conexao)
                }
            }
        }
        try await consumo.value

        // A metade que importa tanto quanto a economia: **nada se perde**. O
        // último gatilho sempre tem um retrato depois dele, e a leitura sai numa
        // transação sua — então o retrato final é o estado final.
        #expect(vistos.todas.last == lotes * porLote)
        // E a economia: bem menos que um retrato por lote.
        #expect(vistos.todas.count <= 17, "retratos: \(vistos.todas)")
    }

    @Test("Banco vazio devolve snapshot vazio, e não erro")
    func bancoVazio() async throws {
        // É o estado do app antes da primeira conta: sem conta, a composição
        // fica nas fixtures, e esta fonte tem de saber dizer "não tenho nada"
        // sem lançar.
        let snapshot = try await DatabaseMailSource(database: try SyncDatabase.temporary()).snapshot()
        #expect(snapshot.accounts.isEmpty)
        #expect(snapshot.messages.isEmpty)
    }

    @Test("As mensagens vêm da mais recente para a mais antiga")
    func ordemPorData() async throws {
        // A mesma ordem que `visibleMessages` do Marco 1 aplica em memória —
        // ela vem do índice `message_on_received`, cujo plano a Task 5 já
        // provou por `EXPLAIN QUERY PLAN`.
        let db = try SyncDatabase.temporary()
        try await semeia(db)
        try await db.pool.write { conexao in
            let antiga = Message(
                id: "m0", accountID: "conta-a",
                from: Contact(name: "Antigo", address: "a@x.com"),
                receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
                subject: "Velho", snippet: "Velho", body: [],
                tags: [], bucket: .today, isRead: false,
                summary: nil, detectedEvent: nil
            )
            try MessageRecord(antiga, folderID: "conta-a/INBOX").insert(conexao)
        }
        let snapshot = try await DatabaseMailSource(database: db).snapshot()
        #expect(snapshot.messages.map(\.id) == ["m1", "m0"])
    }
}

/// As contagens dos retratos que chegaram, guardadas de fora da tarefa que os
/// consome. Caixa com cadeado, e não `actor`: quem lê é o corpo do teste,
/// síncrono, depois de a tarefa terminar.
private final class Contagens: @unchecked Sendable {
    private let lock = NSLock()
    private var lista: [Int] = []

    func registra(_ quantas: Int) {
        lock.lock()
        lista.append(quantas)
        lock.unlock()
    }

    var todas: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return lista
    }
}

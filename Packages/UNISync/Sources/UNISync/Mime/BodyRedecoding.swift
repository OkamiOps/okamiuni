import Foundation
import GRDB
import os

/// A varredura que conserta os corpos que **já estão** no banco.
///
/// **Migração de dados, não de esquema.** Nenhuma coluna nasce ou muda aqui: o
/// que muda é o conteúdo de `message_body.paragraphs`/`plain` das linhas que
/// guardaram fonte MIME em vez de leitura. Por isso ela não entra no
/// `DatabaseMigrator` — uma migração registrada roda uma vez e nunca mais, e o
/// que precisa acontecer aqui é o contrário: rodar sempre que houver o que
/// consertar, inclusive sobre linhas que uma versão intermediária do app tenha
/// gravado cruas depois da primeira passada.
///
/// **Converge sozinha.** Um corpo consertado deixa de parecer cru
/// (`MimeBody.looksRaw` passa a dizer não), então a segunda abertura o lê e não
/// o toca; a terceira, idem. O custo em regime é uma leitura do texto dos
/// corpos, em lotes — nunca uma escrita.
///
/// **Não toca rede.** As 39 mensagens sem corpo nenhum do dono não são deste
/// caminho: elas não têm o que re-decodificar, e quem as resolve é a busca por
/// demanda (`BodyFetching`). Esta varredura é para as outras 44.
public enum BodyRedecoding {
    /// Quantos corpos por leitura. O suficiente para a viagem ao SQLite valer,
    /// e pequeno o bastante para o texto de um lote caber na memória sem
    /// susto — um corpo pode ter centenas de kB.
    public static let loteDeLeitura = 200

    private static let log = Logger(subsystem: "com.okamiops.okamiuni", category: "BodyRedecoding")

    /// Percorre os corpos e reescreve os que são fonte MIME crua. Devolve
    /// quantos foram reescritos.
    ///
    /// A decodificação acontece **fora** da transação de escrita, e a escrita
    /// leva só o que mudou: decodificar dentro do `write` seguraria o escritor
    /// único do banco durante o trabalho de CPU do lote inteiro — e a carga
    /// inicial de uma conta pode estar acontecendo ao lado.
    @discardableResult
    public static func run(_ database: SyncDatabase) async throws -> Int {
        var ultimoRowID: Int64 = 0
        var reescritos = 0

        while true {
            try Task.checkCancellation()
            let daqui = ultimoRowID
            let lote = try await database.pool.read { db in
                try MessageBodyRecord
                    .filter(Column("rowid") > daqui)
                    .order(Column("rowid"))
                    .limit(loteDeLeitura)
                    .fetchAll(db)
            }
            guard let fim = lote.last?.rowid else { break }
            ultimoRowID = fim

            let consertos: [Conserto] = lote.compactMap { registro in
                guard let rowid = registro.rowid else { return nil }
                let velhos = registro.body
                guard let novos = MimeBody.redecodedBody(velhos) else { return nil }
                return Conserto(
                    rowid: rowid, messageID: registro.messageID,
                    velhoPrimeiroParagrafo: velhos.first,
                    paragrafos: novos.paragraphs, html: novos.html
                )
            }

            if !consertos.isEmpty {
                try await database.pool.write { db in
                    for conserto in consertos { try aplica(conserto, em: db) }
                }
                reescritos += consertos.count
            }
        }

        if reescritos > 0 {
            log.info("Corpos re-decodificados na abertura: \(reescritos, privacy: .public).")
        }
        return reescritos
    }

    private struct Conserto: Sendable {
        let rowid: Int64
        let messageID: String
        /// O primeiro parágrafo **de antes**, para saber se a prévia da lista
        /// tinha sido tirada dele.
        let velhoPrimeiroParagrafo: String?
        let paragrafos: [String]
        /// A página, quando o que estava gravado como texto era o **fonte** de
        /// uma. `nil` nos outros casos, e aí a coluna `html` fica como estava:
        /// um corpo que nunca teve HTML não ganha um `""` que faria o leitor
        /// parar de rebuscá-lo.
        let html: String?
    }

    /// Uma linha consertada.
    ///
    /// O `update` (e não um `insert` novo) é o que faz o gatilho
    /// `message_body_au` da v1 disparar: ele apaga a entrada velha do índice
    /// FTS e insere a nova, e é por isso que a busca passa a achar o texto
    /// decodificado sem que nada aqui saiba que o FTS existe.
    private static func aplica(_ conserto: Conserto, em db: Database) throws {
        guard var registro = try MessageBodyRecord.fetchOne(db, key: conserto.rowid) else { return }
        let novo = MessageBodyRecord(messageID: conserto.messageID, paragraphs: conserto.paragrafos)
        registro.paragraphs = novo.paragraphs
        registro.plain = novo.plain
        // O corpo que era fonte HTML passa a ter as duas metades: a leitura em
        // texto (que o FTS reindexa pelo gatilho de UPDATE) e a página, que é o
        // que o leitor desenha desde a M3-8. Sem esta linha, o conserto
        // devolveria prosa sem imagem nenhuma no lugar do email.
        if let pagina = conserto.html { registro.html = pagina }
        try registro.update(db)

        // A prévia da lista também estava crua.
        //
        // Ela é gravada como `corpo.first ?? assunto` na carga IMAP — então a
        // linha da caixa de entrada vinha mostrando `--fronteira` ou
        // `Content-Type: multipart/alternative;` como resumo da mensagem.
        // Consertar o corpo e deixar a prévia mentindo seria consertar metade
        // do que a pessoa vê.
        //
        // A troca é condicional: só quando a prévia **é** o parágrafo velho. A
        // prévia do Gmail vem da API (`snippet`), não do corpo, e sobrescrevê-la
        // trocaria um resumo bom do servidor por uma primeira linha qualquer.
        guard let velha = conserto.velhoPrimeiroParagrafo, let nova = conserto.paragrafos.first
        else { return }
        try db.execute(
            sql: "UPDATE message SET snippet = ? WHERE id = ? AND snippet = ?",
            arguments: [nova, conserto.messageID, velha]
        )
    }
}

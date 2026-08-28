import Foundation
import GRDB

/// A busca no **corpo**, no banco.
///
/// O `MailStore` do Marco 1 procura em remetente, assunto e prévia, dobrando
/// acento em memória. Isso continua valendo e não muda — o que faltava era o
/// corpo, que não está carregado. Esta consulta é o que o `DatabaseMailSource`
/// expõe por `MailSource.bodyMatches(_:)`.
public enum MessageSearch {
    /// O termo digitado virado consulta FTS5, ou `nil` quando não sobra nada
    /// para procurar.
    ///
    /// Cada palavra vira um termo entre aspas (que é como o FTS5 escapa
    /// qualquer coisa), e a **última** ganha `*` de prefixo: quem está
    /// digitando "revis" espera achar "revisão" antes de terminar a palavra,
    /// mas quem já escreveu "revisão do" não quer que "do" case com "domingo".
    ///
    /// Devolver `nil` em vez de uma string vazia não é preciosismo: `MATCH ''`
    /// e `MATCH '"'` são erro de sintaxe no SQLite, e um erro de sintaxe no
    /// caminho da digitação derruba a busca a cada tecla.
    public static func ftsQuery(_ term: String) -> String? {
        let palavras = term
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !palavras.isEmpty else { return nil }
        var partes = palavras.map { "\"\($0)\"" }
        partes[partes.count - 1] += "*"
        return partes.joined(separator: " ")
    }

    /// Os ids das mensagens cujo corpo casa. `accountID` nulo abrange todas.
    public static func matchingBodyIDs(
        _ db: Database, term: String, accountID: String?
    ) throws -> Set<String> {
        guard let consulta = ftsQuery(term) else { return [] }
        var sql = """
            SELECT b.messageID
            FROM message_fts f
            JOIN message_body b ON b.rowid = f.rowid
            JOIN message m ON m.id = b.messageID
            WHERE message_fts MATCH ?
            """
        var argumentos: [DatabaseValueConvertible] = [consulta]
        if let accountID {
            sql += " AND m.accountID = ?"
            argumentos.append(accountID)
        }
        return try String.fetchSet(db, sql: sql, arguments: StatementArguments(argumentos))
    }
}

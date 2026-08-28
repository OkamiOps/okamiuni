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
    ///
    /// A última palavra também tem piso de dois caracteres: é ela quem ganha
    /// `*` de prefixo, e um prefixo de uma letra só (a primeira tecla
    /// digitada) casaria com uma fração enorme do índice — sem seletividade
    /// nenhuma, no caminho que roda a cada tecla.
    public static func ftsQuery(_ term: String) -> String? {
        let palavras = term
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard let ultima = palavras.last, ultima.count >= 2 else { return nil }
        var partes = palavras.map { "\"\($0)\"" }
        partes[partes.count - 1] += "*"
        return partes.joined(separator: " ")
    }

    /// Limite de resultados de uma busca. Digitando por tecla, ninguém rola
    /// além disto antes de refinar o termo — e sem teto, um termo comum sobre
    /// uma caixa grande devolveria milhares de ids para a UI descartar.
    ///
    /// O argumento só vale com a ordem que vem junto dele (ver abaixo): um teto
    /// sem ordem não é um teto, é um filtro enviesado.
    private static let limiteDeResultados = 200

    /// Os ids das mensagens cujo corpo casa. `accountID` nulo abrange todas.
    ///
    /// **Os 200 mais recentes**, e não "200 quaisquer". Sem `ORDER BY`, a ordem
    /// é a do percurso do índice FTS — ordem de `rowid`, isto é, ordem de
    /// inserção: os 200 devolvidos eram os **mais antigos**. Medido num banco de
    /// 50 mil mensagens: de 1 000 corpos que casavam, os 200 devolvidos cobriam
    /// os primeiros 20 % da faixa de datas, e toda a metade recente ficava
    /// invisível. Como o resultado é um `Set` que a UI interseca, o corte era
    /// mudo — não havia "mostrando 200 de 1 000", só ausência.
    ///
    /// O `JOIN message` já existia (é ele que filtra por conta), então a ordem
    /// não traz tabela nova para a consulta.
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
        sql += " ORDER BY m.receivedAt DESC LIMIT \(limiteDeResultados)"
        return try String.fetchSet(db, sql: sql, arguments: StatementArguments(argumentos))
    }
}

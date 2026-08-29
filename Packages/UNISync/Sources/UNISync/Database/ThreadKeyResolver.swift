import Foundation
import GRDB

/// A chave da conversa **com o banco por perto**.
///
/// `ThreadKey` é pura e decide a partir do que a mensagem carrega. Este arquivo
/// acrescenta a única coisa que os cabeçalhos sozinhos não dão: a chave da
/// **mensagem-mãe**, que já está gravada.
///
/// ## Por que a herança importa
///
/// No IMAP a corrente completa (`References`) não vem no `ENVELOPE` — só
/// `In-Reply-To`, que é um elo. Numa conversa de três, a terceira responde à
/// segunda: pela regra pura ela abriria uma conversa nova com a chave da
/// segunda, e a tela mostraria duas linhas onde o webmail mostra uma. Foi
/// exatamente essa a queixa que abriu esta tarefa.
///
/// Perguntando ao banco pela mãe, a corrente se reconstrói elo a elo: a segunda
/// já herdou a chave da primeira, então a terceira herda a mesma. Custa uma
/// consulta por mensagem **nova**, num índice feito para ela
/// (`message_on_rfc_message_id`) — e não uma por linha da lista, que é o que
/// derivar na leitura custaria.
///
/// A herança também é o que faz a **resposta enviada** cair na conversa certa
/// numa conta Gmail: a chave da conversa lá é o `threadId`, que a
/// `messages.send` não nos devolve — mas a mensagem respondida está no banco
/// com ele, e a cópia em Enviadas o herda.
enum ThreadKeyResolver {
    /// A chave desta mensagem, resolvida na transação em que ela vai ser
    /// gravada.
    ///
    /// A ordem é: **a mãe primeiro** (a chave dela é a verdade mais forte que
    /// existe aqui, e é a única que atravessa provedores), depois as regras
    /// puras de `ThreadKey`.
    static func resolve(
        _ db: Database,
        accountID: String,
        messageID: String?,
        inReplyTo: String?,
        references: [String],
        subject: String,
        fallback: String
    ) throws -> String {
        // Do elo mais próximo para o mais distante: a mãe, depois a avó. A
        // primeira que estiver no banco manda — as de cima têm a mesma chave,
        // então parar na primeira não perde nada.
        let ancestrais = ([inReplyTo].compactMap { $0 } + references.reversed())
            .map(ThreadKey.bare)
            .filter { !$0.isEmpty }
        for ancestral in ancestrais {
            if let herdada = try chave(db, accountID: accountID, rfcMessageID: ancestral) {
                return herdada
            }
        }
        return ThreadKey.derive(
            accountID: accountID, messageID: messageID, inReplyTo: inReplyTo,
            references: references, subject: subject, fallback: fallback
        )
    }

    /// A chave de uma mensagem que já está no banco, achada pelo `Message-ID`
    /// dela. `nil` quando ela não está lá — o caso normal da primeira mensagem
    /// de uma conversa, e o da conversa cuja raiz ficou fora dos 90 dias.
    static func chave(
        _ db: Database, accountID: String, rfcMessageID: String
    ) throws -> String? {
        try String.fetchOne(
            db,
            sql: """
                SELECT threadKey FROM message
                WHERE accountID = ? AND rfcMessageID = ? AND threadKey IS NOT NULL
                LIMIT 1
                """,
            arguments: [accountID, rfcMessageID]
        )
    }
}

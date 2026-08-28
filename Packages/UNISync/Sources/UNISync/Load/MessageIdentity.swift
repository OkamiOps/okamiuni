import Foundation

/// O `Message.id` nosso, a partir do que o servidor deu.
///
/// **Determinístico, nunca `UUID()`.** Reabrir o app e recarregar a mesma
/// mensagem tem de encontrar a linha que já existe — é o que faz a carga
/// inicial ser retomável e o `INSERT OR REPLACE` do lote ser idempotente. Com
/// `UUID()`, cada carga duplicaria a caixa inteira.
///
/// O prefixo da conta é o que impede duas contas com o mesmo id de servidor de
/// colidirem — e elas colidem: dois Gmail da mesma pessoa compartilham o
/// formato de id, e dois IMAP compartilham o UID 1.
public enum MessageIdentity {
    public static func gmail(accountID: String, serverID: String) -> String {
        "\(accountID):g:\(serverID)"
    }

    /// O IMAP precisa dos quatro pedaços.
    ///
    /// A pasta entra porque a mesma mensagem em duas pastas são, para o IMAP,
    /// dois UIDs diferentes — e são duas linhas nossas também. O `UIDVALIDITY`
    /// entra porque o servidor pode reciclar os UIDs desde 1: sem ele, o UID 1
    /// de ontem casaria com o UID 1 de hoje e a lista mostraria a mensagem
    /// errada com o assunto certo.
    public static func imap(accountID: String, folderID: String, uidValidity: Int64, uid: Int64) -> String {
        "\(accountID):i:\(folderID):\(uidValidity):\(uid)"
    }
}

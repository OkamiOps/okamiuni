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

    /// As coordenadas do servidor **de volta**, a partir do nosso id.
    ///
    /// É o caminho inverso das duas funções acima, e ele existe por uma razão
    /// concreta do executor da fila: `deletePermanently` e `emptyTrash` apagam
    /// a linha de `message` na **mesma transação** em que enfileiram a
    /// operação (ver `DatabaseCommandPort`). Quando o executor acorda, a linha
    /// já não existe — e ler o servidor a partir de uma tabela vazia
    /// devolveria "nada a fazer" para uma operação que ainda não aconteceu:
    /// perda silenciosa, exatamente o que o invariante da fila proíbe.
    ///
    /// O id, ao contrário da linha, é o que a operação carrega no JSON dela —
    /// e ele já contém tudo: o id do servidor, no Gmail; a pasta, o
    /// `UIDVALIDITY` e o UID, no IMAP. Decodificá-lo é ler o que já está na
    /// mão, e não um segundo cadastro para manter em dia.
    public static func parse(_ id: String, accountID: String) -> MessageCoordinate? {
        if let resto = semPrefixo(id, prefixo: "\(accountID):g:") {
            return resto.isEmpty ? nil : .gmail(serverID: resto)
        }
        guard let resto = semPrefixo(id, prefixo: "\(accountID):i:") else { return nil }
        // A leitura é **de trás para a frente**: `uid` e `uidValidity` são os
        // dois últimos campos, e o que sobra na frente é o `folderID` inteiro.
        // Cortar do começo erraria em qualquer pasta cujo nome tenha `:` —
        // legal no IMAP, e comum em pastas de calendário de alguns provedores.
        let partes = resto.split(separator: ":", omittingEmptySubsequences: false)
        guard partes.count >= 3,
              let uid = Int64(partes[partes.count - 1]),
              let uidValidity = Int64(partes[partes.count - 2])
        else { return nil }
        let folderID = partes[0..<(partes.count - 2)].joined(separator: ":")
        // `folderID` é `accountID/nomeNoServidor` (ver `FolderRecord.id`), e o
        // que o comando IMAP precisa é o nome no servidor.
        let prefixo = "\(accountID)/"
        guard folderID.hasPrefix(prefixo) else { return nil }
        let pasta = String(folderID.dropFirst(prefixo.count))
        guard !pasta.isEmpty else { return nil }
        return .imap(folderName: pasta, uidValidity: uidValidity, uid: uid)
    }

    private static func semPrefixo(_ texto: String, prefixo: String) -> String? {
        guard texto.hasPrefix(prefixo) else { return nil }
        return String(texto.dropFirst(prefixo.count))
    }
}

/// Onde uma mensagem mora **no servidor** — o que o espelho da triagem precisa
/// saber para escrever de volta.
///
/// Dois casos porque são dois protocolos, e não um denominador comum: o Gmail
/// endereça por id opaco e não tem pasta; o IMAP endereça por (pasta, geração
/// de UIDs, UID) e não tem id global. Um tipo único com campos opcionais
/// deixaria cada espelho conferindo os campos do outro.
public enum MessageCoordinate: Sendable, Hashable {
    case gmail(serverID: String)
    case imap(folderName: String, uidValidity: Int64, uid: Int64)
}

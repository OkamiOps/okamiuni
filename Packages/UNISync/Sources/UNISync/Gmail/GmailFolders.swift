import Foundation
import GRDB
import UNICore

/// Quais rótulos do Gmail são **pastas**, e que papel cada um cumpre.
///
/// ## Por que isto existe
///
/// No Gmail não há pastas: há rótulos, e uma mensagem tem vários ao mesmo
/// tempo. Mas a pessoa que pediu "as caixas têm que ter a opção de expandir e
/// mostrar as outras pastas do provider" não está pedindo uma taxonomia — ela
/// quer ver "Faturas" e clicar. Rótulo do usuário **é** a pasta dele, e é assim
/// que todo cliente de email trata.
///
/// ## O que fica de fora, e por quê
///
/// Nem todo rótulo do sistema é um lugar. `UNREAD` e `STARRED` são **estados**
/// da mensagem — o app já os mostra como bandeira e como contador, e uma linha
/// "STARRED" na barra seria a mesma informação uma segunda vez, com cara de
/// pasta. `IMPORTANT` é um palpite do Gmail, `CHAT` é outro produto, e as
/// `CATEGORY_*` (Promoções, Social, Atualizações…) são as abas da caixa de
/// entrada dele: elas não guardam nada que `INBOX` já não guarde, e listá-las
/// mostraria a mesma mensagem em quatro linhas da barra.
///
/// Sobram cinco do sistema — os cinco que **são** lugares de verdade, e que têm
/// gêmeo exato numa conta IMAP — e **todos** os do usuário.
public enum GmailFolders {
    /// Os rótulos do sistema que viram pasta, e o papel de cada um. A tabela é
    /// a tradução do `SPECIAL-USE` do IMAP para o vocabulário do Gmail, e mora
    /// ao lado dela em espírito: `FolderRoles` decide pelo atributo, esta
    /// decide pelo id.
    ///
    /// `TRASH` e `SPAM` estão aqui e `ARCHIVE` não: o Gmail não tem rótulo de
    /// arquivo — arquivado lá é "sem `INBOX`" —, e inventar uma linha "Arquivo"
    /// que nenhum rótulo produz seria uma pasta que o webmail não tem. Quem
    /// mostra o arquivado é a caixa Arquivado do Fluxo.
    static let systemRoles: [String: FolderRole] = [
        "INBOX": .inbox,
        "SENT": .sent,
        "DRAFT": .drafts,
        "SPAM": .junk,
        "TRASH": .trash,
    ]

    /// Este id de rótulo é uma pasta?
    ///
    /// **Pura, e sem a lista de rótulos na mão**, de propósito: ela é chamada
    /// uma vez por mensagem gravada, dentro da transação do lote, para decidir a
    /// pertinência da linha. Precisar da listagem ali obrigaria a carregá-la
    /// junto em todo caminho de escrita — inclusive nos que não a têm.
    ///
    /// O que ela sabe é o que basta: os cinco do sistema que entram, os quatro
    /// que não entram, o prefixo das abas, e "o resto é do usuário". Um rótulo
    /// de sistema novo que o Google invente cairia como do usuário e apareceria
    /// na barra — errar para o lado de mostrar, como no `type` ausente.
    public static func isFolderLabel(_ id: String) -> Bool {
        if systemRoles[id] != nil { return true }
        if id.hasPrefix("CATEGORY_") { return false }
        return !["UNREAD", "STARRED", "IMPORTANT", "CHAT"].contains(id)
    }

    /// O papel de um rótulo: o da tabela quando ele é do sistema, `.other`
    /// quando é do usuário — pasta que a pessoa criou não tem papel nosso, a
    /// mesma resposta que `FolderRoles` dá a uma pasta IMAP dela.
    public static func role(labelID: String) -> FolderRole {
        systemRoles[labelID] ?? .other
    }

    /// As linhas de `folder` que uma listagem de rótulos produz.
    ///
    /// O `serverName` é o **id** do rótulo, e não o nome: ele é opaco e estável,
    /// e é o nome que muda quando a pessoa renomeia "Faturas" para "Faturas
    /// 2026". Com o id na chave, renomear atualiza a linha; com o nome, criaria
    /// uma segunda pasta ao lado, com as mensagens partidas em duas.
    public static func records(_ labels: [GmailLabel], accountID: String) -> [FolderRecord] {
        labels
            .filter { $0.type != "system" || systemRoles[$0.id] != nil }
            .filter { isFolderLabel($0.id) }
            .map { rotulo in
                FolderRecord(
                    id: FolderRecord.id(accountID: accountID, serverName: rotulo.id),
                    accountID: accountID, serverName: rotulo.id,
                    role: role(labelID: rotulo.id),
                    displayName: nomeVisivel(rotulo.name)
                )
            }
    }

    /// Em que pastas uma mensagem está, pelos rótulos que ela carrega.
    public static func membership(labelIDs: [String], accountID: String) -> [String] {
        labelIDs
            .filter(isFolderLabel)
            .map { FolderRecord.id(accountID: accountID, serverName: $0) }
    }

    /// O nome que a linha escreve.
    ///
    /// Os cinco do sistema chegam em maiúsculas e em inglês (`INBOX`, `SENT`),
    /// porque o `name` deles **é** o id. Traduzi-los é o mínimo para a barra não
    /// misturar "SENT" com "Faturas" na mesma coluna. Os do usuário passam
    /// intactos: o nome deles é o que a pessoa digitou, inclusive a hierarquia
    /// composta ("Clientes/Faturas"), que é como o Gmail a entrega e como a
    /// barra a mostra.
    static func nomeVisivel(_ name: String) -> String {
        switch name {
        case "INBOX": "Entrada"
        case "SENT": "Enviados"
        case "DRAFT": "Rascunhos"
        case "SPAM": "Spam"
        case "TRASH": "Lixeira"
        default: name
        }
    }
}

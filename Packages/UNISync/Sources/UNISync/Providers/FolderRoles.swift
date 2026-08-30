import Foundation
import UNICore

/// Que papel uma pasta do servidor cumpre para nós.
///
/// Duas fontes, nesta ordem de confiança: o atributo `SPECIAL-USE`, quando o
/// servidor o dá, e o nome, quando não dá. A parte do nome é uma tabela pura e
/// testável de propósito — é o pedaço que mais varia entre provedores e o que
/// mais vai precisar de conserto, e conserto de heurística sem teste é aposta.
public enum FolderRoles {
    /// A pasta que o Marco 3 vai criar para espelhar a caixa "Depois". Aqui
    /// ela só é **lida**, se já existir de instalação anterior.
    public static let laterFolderName = "OkamiUNI/Depois"

    public static func role(specialUse: String?, name: String) -> FolderRole {
        // A nossa pasta ganha de qualquer atributo: ela é nossa, o significado
        // é nosso, e um servidor que a marcasse como arquivo não sabe disso.
        if fold(name) == fold(laterFolderName) { return .later }

        if let specialUse {
            switch fold(specialUse) {
            case "\\inbox": return .inbox
            // `\All` é o "Todos os e-mails" do Gmail, que é o arquivo dele.
            case "\\archive", "\\all": return .archive
            case "\\trash": return .trash
            case "\\sent": return .sent
            // `\Drafts` e `\Junk` ganharam papel na M3-17. Eles continuam
            // **fora do fluxo de triagem** — a projeção manda os dois para
            // Arquivado, exatamente como mandava quando eram `.other` —, e o
            // que o papel compra é o ícone da linha na barra lateral. Ver
            // `FolderRole.drafts`.
            case "\\drafts": return .drafts
            case "\\junk": return .junk
            default: break
            }
        }

        let dobrado = fold(name)
        if dobrado == "inbox" || dobrado == "caixa de entrada" { return .inbox }
        let folha = lastPathComponent(of: dobrado)
        for sufixo in ["archive", "arquivo", "all mail", "todos os e-mails", "todos os emails"]
        where folha == sufixo {
            return .archive
        }
        for sufixo in ["trash", "lixeira", "deleted messages", "deleted items", "itens excluidos"]
        where folha == sufixo {
            return .trash
        }
        for sufixo in ["sent", "sent items", "sent messages", "enviados", "itens enviados"]
        where folha == sufixo {
            return .sent
        }
        for sufixo in ["drafts", "draft", "rascunhos", "rascunho"]
        where folha == sufixo {
            return .drafts
        }
        for sufixo in ["junk", "junk email", "spam", "lixo eletronico", "bulk mail"]
        where folha == sufixo {
            return .junk
        }
        return .other
    }

    /// O servidor anuncia o delimitador no `LIST`/`NAMESPACE`, mas o papel só
    /// precisa da folha. Aceitar os três delimitadores comuns também faz
    /// `INBOX.Sent` (Dovecot) cair no mesmo papel de `[Gmail]/Sent`.
    private static func lastPathComponent(of text: String) -> String {
        text.split(whereSeparator: { $0 == "/" || $0 == "." || $0 == "\\" }).last.map(String.init) ?? text
    }

    /// Caixa e acento fora. A mesma dobra do resto do app —
    /// `ContactDirectory.fold` é a única definição, e esta chama aquela em vez
    /// de virar uma segunda resposta para a mesma pergunta.
    private static func fold(_ text: String) -> String {
        ContactDirectory.fold(text.trimmingCharacters(in: .whitespaces))
    }
}

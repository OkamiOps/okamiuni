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
            // `\Drafts` e `\Junk` existem e não têm papel nosso — cair em
            // `.other` é a resposta certa, não uma lacuna.
            default: break
            }
        }

        let dobrado = fold(name)
        if dobrado == "inbox" || dobrado == "caixa de entrada" { return .inbox }
        for sufixo in ["archive", "arquivo", "all mail", "todos os e-mails", "todos os emails"]
        where dobrado == sufixo || dobrado.hasSuffix("/" + sufixo) {
            return .archive
        }
        for sufixo in ["trash", "lixeira", "deleted messages", "deleted items", "itens excluidos"]
        where dobrado == sufixo || dobrado.hasSuffix("/" + sufixo) {
            return .trash
        }
        for sufixo in ["sent", "sent items", "sent messages", "enviados", "itens enviados"]
        where dobrado == sufixo || dobrado.hasSuffix("/" + sufixo) {
            return .sent
        }
        return .other
    }

    /// Caixa e acento fora. A mesma dobra do resto do app —
    /// `ContactDirectory.fold` é a única definição, e esta chama aquela em vez
    /// de virar uma segunda resposta para a mesma pergunta.
    private static func fold(_ text: String) -> String {
        ContactDirectory.fold(text.trimmingCharacters(in: .whitespaces))
    }
}

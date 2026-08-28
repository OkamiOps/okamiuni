import Foundation
import UNICore

/// Os tipos e os comandos do IMAP, na parte que é nossa.
///
/// **Montar comando é nosso e é puro; interpretar resposta é da biblioteca.**
/// Essa divisão não é arbitrária: o que a gente manda é um punhado de linhas
/// ASCII com regras simples de citação, e é onde erram os escapes e o formato
/// de data — dois defeitos que um teste puro pega em milissegundos. O que o
/// servidor manda de volta é gramática de verdade, com literais de tamanho
/// declarado e continuação, e é para isso que o `swift-nio-imap` existe.
public enum ImapWire {
    // MARK: Tipos

    public struct Folder: Sendable, Hashable {
        public let name: String
        public let specialUse: String?
        public let role: FolderRole

        public init(name: String, specialUse: String?) {
            self.name = name
            self.specialUse = specialUse
            role = FolderRoles.role(specialUse: specialUse, name: name)
        }
    }

    // MARK: Comandos

    /// Tag de largura fixa: `A0001`. Largura fixa porque os logs do servidor e
    /// os nossos ficam alinháveis, e porque o servidor falso casa por prefixo.
    public static func tag(_ n: Int) -> String { String(format: "A%04d", n) }

    /// Uma string entre aspas, com `\` e `"` escapados — a regra do RFC 3501.
    ///
    /// Sem isto, uma senha de app com aspas dentro quebra o comando e o
    /// servidor responde `BAD`, que a pessoa lê como "senha errada" e passa a
    /// tarde trocando a senha certa.
    public static func quoted(_ s: String) -> String {
        let escapado = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escapado)\""
    }

    public static func login(tag: String, user: String, password: String) -> String {
        "\(tag) LOGIN \(quoted(user)) \(quoted(password))"
    }

    /// O comando que sobe a conexão em claro para TLS, antes de qualquer
    /// credencial. Só existe no caminho `.startTLS`; em `.tls` o TLS já começou
    /// no primeiro byte e este comando seria um erro de protocolo.
    public static func startTLS(tag: String) -> String { "\(tag) STARTTLS" }

    public static func list(tag: String) -> String { "\(tag) LIST \"\" \"*\"" }

    public static func select(tag: String, mailbox: String) -> String {
        "\(tag) SELECT \(quoted(mailbox))"
    }

    /// `dd-MMM-yyyy` com meses em **inglês**, sempre.
    ///
    /// Um `DateFormatter` com o locale da máquina manda `25-ago-2026`, e o
    /// servidor responde `BAD`. É a mesma família do bug de fuso registrado em
    /// `docs/decisoes-de-engenharia.md`: formato de protocolo não pode nascer
    /// de uma conversão que a máquina do usuário decide.
    public static func imapDate(_ date: Date, calendar: Calendar) -> String {
        let meses = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let partes = calendar.dateComponents([.day, .month, .year], from: date)
        let dia = partes.day ?? 1
        let mes = meses[max(0, min(11, (partes.month ?? 1) - 1))]
        return String(format: "%02d-%@-%04d", dia, mes, partes.year ?? 1970)
    }

    public static func uidSearchSince(tag: String, date: Date, calendar: Calendar) -> String {
        "\(tag) UID SEARCH SINCE \(imapDate(date, calendar: calendar))"
    }

    /// Envelopes em lote. Um `FETCH` por mensagem seria uma ida e volta por
    /// mensagem; a conta de 90 dias tem milhares.
    public static func uidFetchEnvelopes(tag: String, uids: [Int64]) -> String {
        let conjunto = uids.map(String.init).joined(separator: ",")
        return "\(tag) UID FETCH \(conjunto) (UID FLAGS INTERNALDATE ENVELOPE)"
    }

    /// O corpo em texto de uma mensagem. `BODY.PEEK` e não `BODY`: `BODY` marca
    /// a mensagem como lida no servidor, e baixar o corpo para o cache não é a
    /// pessoa ter lido nada.
    public static func uidFetchBody(tag: String, uid: Int64) -> String {
        "\(tag) UID FETCH \(uid) (BODY.PEEK[TEXT])"
    }

    public static func logout(tag: String) -> String { "\(tag) LOGOUT" }
}

public typealias ImapFolder = ImapWire.Folder

public struct ImapMailboxStatus: Sendable, Hashable {
    public let uidValidity: Int64
    public let uidNext: Int64
    public let exists: Int

    public init(uidValidity: Int64, uidNext: Int64, exists: Int) {
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.exists = exists
    }
}

public struct ImapEnvelope: Sendable, Hashable {
    public let uid: Int64
    public let from: Contact
    public let to: [Contact]
    public let cc: [Contact]
    public let subject: String
    public let date: Date
    public let isRead: Bool
    public let isFlagged: Bool

    public init(
        uid: Int64, from: Contact, to: [Contact], cc: [Contact],
        subject: String, date: Date, isRead: Bool, isFlagged: Bool
    ) {
        self.uid = uid
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.date = date
        self.isRead = isRead
        self.isFlagged = isFlagged
    }
}

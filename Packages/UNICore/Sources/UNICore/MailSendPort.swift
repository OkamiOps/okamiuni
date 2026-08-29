import Foundation

/// Um endereço de uma mensagem que **vai sair**.
///
/// Não é `Contact` por uma razão só: `Contact` é do desenho (ele tem
/// `initials`, ele é `Identifiable` para a lista), e o que atravessa a porta de
/// envio precisa ser `Codable` — a operação de envio viaja no JSON do `outbox`
/// e volta de lá depois de o app ter sido fechado e reaberto. Dar `Codable` a
/// `Contact` seria pendurar no tipo da UI uma responsabilidade que só a fila
/// tem.
public struct OutgoingAddress: Codable, Sendable, Hashable {
    public let name: String
    public let address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }

    public init(_ contact: Contact) {
        self.init(name: contact.name, address: contact.address)
    }
}

/// A mensagem que a janela do composer entregou para sair.
///
/// **Ela nasce pronta.** O corpo já vem em texto simples e — quando houve
/// formatação — em HTML: a conversão de `AttributedString` para HTML mora no
/// `UNIShell`, do lado do AppKit, porque `UNICore` e `UNISync` não importam
/// SwiftUI nem AppKit. Aqui atravessam duas `String`, e o `UNISync` monta o
/// RFC 5322 a partir delas sem nunca saber que existiu um `NSTextView`.
///
/// `messageID` é gerado **uma vez**, na criação, e é o que torna o reenvio
/// seguro: depois de um tempo esgotado ambíguo (o servidor aceitou e a resposta
/// não chegou), quem reexecuta pergunta ao servidor se uma mensagem com este
/// `Message-ID` já está em Enviadas antes de mandar de novo. Um id sorteado a
/// cada tentativa transformaria toda queda de rede numa mensagem duplicada na
/// caixa de quem recebe — e essa é a duplicata que ninguém consegue desfazer.
public struct OutgoingMessage: Codable, Sendable, Hashable {
    /// O `Message-ID` **sem** os sinais de menor e maior: `uuid@dominio`. Quem
    /// escreve o cabeçalho põe os `<>`; quem pergunta ao Gmail
    /// (`rfc822msgid:`) precisa dele pelado. Guardar a forma pelada é guardar a
    /// que não tem duas leituras.
    public let messageID: String
    public let accountID: String
    public let from: OutgoingAddress
    public let to: [OutgoingAddress]
    public let cc: [OutgoingAddress]
    /// A cópia oculta. **Ela não vira cabeçalho no caminho do SMTP** — vai só
    /// no `RCPT TO`, que é o que a torna oculta. Ver `OutgoingMime.compose`.
    public let bcc: [OutgoingAddress]
    public let subject: String
    /// O corpo em texto simples. Sempre existe: uma mensagem só-HTML é
    /// ilegível em qualquer cliente de texto, e é o que os filtros de spam
    /// leem como sinal.
    public let plainText: String
    /// O corpo em HTML, ou `nil` quando o rascunho não tinha formatação
    /// nenhuma. `nil` é uma mensagem `text/plain` simples, sem `multipart`.
    public let html: String?
    /// O iCalendar de uma resposta de convite. Quando existe, o transportador
    /// envia esta mensagem como `text/calendar` — o composer comum continua
    /// sem esta parte e preserva o MIME atual.
    public let calendarICS: String?
    /// O `Message-ID` da mensagem respondida, sem `<>`.
    public let inReplyTo: String?
    /// A corrente da conversa, sem `<>`, da mais antiga para a mais nova.
    public let references: [String]

    public init(
        messageID: String,
        accountID: String,
        from: OutgoingAddress,
        to: [OutgoingAddress],
        cc: [OutgoingAddress] = [],
        bcc: [OutgoingAddress] = [],
        subject: String,
        plainText: String,
        html: String? = nil,
        calendarICS: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = []
    ) {
        self.messageID = messageID
        self.accountID = accountID
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.plainText = plainText
        self.html = html
        self.calendarICS = calendarICS
        self.inReplyTo = inReplyTo
        self.references = references
    }

    /// Todo mundo que vai receber — é a lista do `RCPT TO`, e é por isso que a
    /// cópia oculta entra nela mesmo não entrando em cabeçalho nenhum.
    public var recipients: [String] {
        var vistos = Set<String>()
        return (to + cc + bcc).map(\.address)
            .filter { !$0.isEmpty && vistos.insert($0.lowercased()).inserted }
    }

    /// Um `Message-ID` novo para uma mensagem que está nascendo.
    ///
    /// O domínio sai do endereço de quem envia, e não de um domínio nosso: um
    /// `Message-ID` com domínio alheio ao remetente é o que alguns filtros
    /// contam como sinal de forja. Endereço sem `@` (o que não deveria chegar
    /// aqui, mas chega quando alguém digita) cai em `localhost`, que é o valor
    /// honesto para "não sei de que domínio isto saiu".
    public static func newMessageID(for address: String) -> String {
        // `split` sobre um endereço sem `@` devolve o endereço inteiro como
        // "domínio" — e o `Message-ID` sairia `uuid@sem-arroba`. A conferência
        // do `contains` é o que faz o caso torto cair em `localhost`.
        let dominio = address.contains("@")
            ? (address.split(separator: "@").last.map(String.init) ?? "")
            : ""
        let limpo = dominio.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(UUID().uuidString.lowercased())@\(limpo.isEmpty ? "localhost" : limpo)"
    }
}

/// Para onde o "Enviar" do composer manda a mensagem.
///
/// Irmã de `MailCommandPort`, e pelo mesmo motivo de morar aqui e não no
/// `UNISync`: quem chama é a janela, e a janela não pode depender de GRDB nem
/// de NIO para apertar um botão.
///
/// Síncrona e lançando, como a outra: enviar **enfileira**, e enfileirar é uma
/// transação SQLite local. A rede acontece depois, no executor da fila — é isso
/// que faz "Enviar" funcionar sem conexão e a mensagem sair sozinha quando ela
/// voltar.
public protocol MailSendPort: Sendable {
    func send(_ message: OutgoingMessage) throws
}

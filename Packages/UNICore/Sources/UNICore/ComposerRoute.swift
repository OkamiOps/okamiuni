import Foundation

/// Com que **intenção** a janela 03 foi aberta, e como essa intenção atravessa
/// uma cena SwiftUI.
///
/// `WindowGroup(id:for:)` carrega um valor `Codable & Hashable`, e o app inteiro
/// usa `String` para isso (ver `UNIWindow`). Até a Task AR o valor da cena
/// `uni.composer` era só o id da mensagem, e a janela só sabia responder. Com
/// "Responder a todos" a mesma cena passa a ter mais de um destino, e ele
/// precisa viajar junto do id.
///
/// **Por que não uma cena por modo.** Uma cena a mais por intenção duplicaria o
/// tamanho declarado, o item de Janela ▸ e o ⌘W de cada uma, e ainda assim
/// deixaria o mesmo problema: `openWindow(id:value:)` devolve a **mesma** janela
/// para o mesmo valor. Codificar a intenção no valor é o que faz "responder à
/// m1" e "responder a todos da m1" serem duas janelas, como em qualquer
/// cliente — e o que faz clicar duas vezes no mesmo item trazer a janela de
/// volta em vez de abrir uma segunda.
///
/// Mora em `UNICore` porque é uma regra de texto pura, e porque `ComposerWindow`
/// é uma `View` — `@MainActor` implícito, de onde um teste nonisolated não
/// alcança.
public enum ComposerRoute: Sendable, Hashable {
    case reply(messageID: String)
    case replyAll(messageID: String)
    case forward(messageID: String)
    /// Reabre um rascunho da caixa Rascunhos — a mesma janela 03/06, já
    /// preenchida com o que foi salvo.
    case draft(messageID: String)

    /// O prefixo de cada intenção. Responder **não tem** prefixo: assim todo
    /// valor que já existia — o `openWindow(id:value:messageID)` do leitor, o
    /// `--responder m1` da linha de comando, uma janela restaurada pelo
    /// sistema — continua significando exatamente o que significava.
    public static let replyAllPrefix = "todos:"
    public static let forwardPrefix = "enc:"
    public static let draftPrefix = "rascunho:"

    /// O texto que a cena carrega.
    public var value: String {
        switch self {
        case .reply(let id): id
        case .replyAll(let id): Self.replyAllPrefix + id
        case .forward(let id): Self.forwardPrefix + id
        case .draft(let id): Self.draftPrefix + id
        }
    }

    public var messageID: String {
        switch self {
        case .reply(let id), .replyAll(let id), .forward(let id), .draft(let id): id
        }
    }

    /// A janela certa para esta mensagem: rascunho reabre o que já estava
    /// escrito; o resto responde.
    public static func editor(for message: Message) -> ComposerRoute {
        message.bucket == .drafts ? .draft(messageID: message.id) : .reply(messageID: message.id)
    }

    /// Lê o valor de volta. Qualquer coisa sem prefixo conhecido é uma
    /// resposta simples — inclusive `""`, que é o que uma cena restaurada sem
    /// valor entrega.
    public static func parse(_ value: String) -> ComposerRoute {
        if value.hasPrefix(replyAllPrefix) {
            return .replyAll(messageID: String(value.dropFirst(replyAllPrefix.count)))
        }
        if value.hasPrefix(forwardPrefix) {
            return .forward(messageID: String(value.dropFirst(forwardPrefix.count)))
        }
        if value.hasPrefix(draftPrefix) {
            return .draft(messageID: String(value.dropFirst(draftPrefix.count)))
        }
        return .reply(messageID: value)
    }
}

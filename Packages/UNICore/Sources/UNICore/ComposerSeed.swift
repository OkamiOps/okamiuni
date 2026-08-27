import Foundation

/// Com o que a janela de resposta nasce.
///
/// Vive aqui, e não dentro da `View`, porque no Swift 6 um `View` é
/// implicitamente `@MainActor` e um `static` dentro dele herda o isolamento —
/// um teste nonisolated que o chamasse trapava em runtime. Já aconteceu nesta
/// base; ver `docs/decisoes-de-engenharia.md`.
public struct ComposerSeed: Sendable, Hashable {
    public let to: [Contact]
    public let subject: String
    /// Texto simples: a faixa de resposta rápida é de texto simples, e o corpo
    /// rico da janela começa sem atributo nenhum a partir daqui.
    public let body: String

    public init(to: [Contact], subject: String, body: String) {
        self.to = to
        self.subject = subject
        self.body = body
    }

    /// Resolve o estado inicial de uma resposta.
    ///
    /// O rascunho vem da faixa embutida no leitor, que grava antes de promover
    /// para a janela cheia. Quando ele existe e tem conteúdo, vence o padrão —
    /// abrir a janela vazia perderia o que a pessoa escreveu, que é pior que
    /// não ter o botão de promover.
    ///
    /// Um rascunho **sem** destinatário não apaga o remetente da mensagem: a
    /// pessoa pode ter escrito o texto e ainda não escolhido para quem vai.
    public static func reply(to message: Message, draft: ReplyDraft?) -> ComposerSeed {
        // Mensagem sem assunto não vira "Re: " pendurado. `ComposerWindow`
        // .windowTitle já trata esse caso devolvendo "Nova mensagem"; o campo
        // Assunto tem de concordar, senão o título e o campo se contradizem na
        // mesma janela.
        let subject = message.subject.isEmpty ? "" : "Re: \(message.subject)"
        guard let draft, !draft.isEmpty else {
            return ComposerSeed(to: [message.from], subject: subject, body: "")
        }
        return ComposerSeed(
            to: draft.to.isEmpty ? [message.from] : draft.to,
            subject: subject,
            body: draft.text
        )
    }
}

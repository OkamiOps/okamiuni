import SwiftUI
import UNICore
import UNIDesign

/// O "Enviar" do dashboard 08 — a pessoa enviando um rascunho que ela viu.
///
/// **A IA nunca envia.** O que sai daqui é sempre um clique humano: na prévia
/// (onde o rascunho aparece inteiro) o clique envia direto; na linha (texto
/// truncado) quem chama primeiro arma a confirmação de uma linha e só o
/// segundo clique chega aqui. Este tipo não fala com motor nenhum — ele monta
/// o `OutgoingMessage` pela **mesma** montagem do composer
/// (`ComposerOutgoing.message`, com `In-Reply-To`/`References` de resposta) e
/// o entrega à fila de saída normal (`MailStore.send`).
///
/// Fora da `View` para o teste alcançar sem clique — e porque a regra "nunca
/// envia sem porta" é decisão, não desenho.
@MainActor
enum DashboardSend {

    /// Envia `text` como resposta a `message`, pela conta que a recebeu.
    /// Devolve `true` quando a mensagem entrou na fila de saída.
    ///
    /// Sem porta de envio (fixtures, ensaios) nada sai e nada é fingido:
    /// devolve `false` e o rascunho continua onde está — perder texto por
    /// causa de uma fila que não existe seria pior do que não enviar.
    @discardableResult
    static func send(
        draft text: String,
        for message: Message,
        in store: MailStore,
        theme: Theme
    ) -> Bool {
        let corpo = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corpo.isEmpty, store.canSend,
              let account = store.account(message.accountID)
        else { return false }

        let content = ComposerOutgoing.content(
            AttributedString(corpo),
            theme: theme,
            signature: account.emailSignature,
            signatureIsInserted: false
        )
        let outgoing = ComposerOutgoing.message(
            accountID: account.id,
            from: Contact(name: account.displayName, address: account.address),
            to: [message.from],
            cc: [],
            bcc: [],
            // O mesmo "Re: " da janela cheia, pela mesma função.
            subject: ComposerSeed.reply(to: message, draft: nil).subject,
            plainText: content.plainText,
            html: content.html,
            inlineResources: content.inlineResources,
            replyingTo: message
        )
        return store.send(outgoing)
    }
}

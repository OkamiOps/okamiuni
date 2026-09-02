import Foundation
import UNICore
import UNISync

/// O texto que a prévia do meio mostra, e por quê.
///
/// A prévia mostrava `message.body` **quando ele já estava hidratado** e o
/// `snippet` quando não — e, como ela nunca pedia corpo nenhum, na caixa de
/// verdade o "quando não" era o caso de sempre: uma frase e 400pt de vazio
/// embaixo. Agora ela pede o corpo pela mesma porta do leitor
/// (`MailStore.loadBodyIfNeeded`) e mostra o que chegar.
///
/// A escolha do texto é decisão pura e mora fora da `View`, pelo motivo de
/// sempre: um teste a prova sem renderizar janela nenhuma.
enum DashboardPreviewBody {

    /// O que a prévia tem para desenhar agora.
    struct State: Equatable {
        /// O texto do email — corpo, HTML legível, ou o resumo enquanto o
        /// corpo não chega. Nunca `nil`: vazio é vazio.
        let text: String
        /// O corpo está sendo buscado. Quem desenha a espera é a barra fina do
        /// chrome (ver `ChromeWorkload`), não uma segunda animação aqui.
        let isWaiting: Bool
        /// A busca falhou, no idioma da pessoa.
        let failure: String?

        var isEmpty: Bool { text.isEmpty }
    }

    /// Vale a pena pedir o corpo desta mensagem?
    ///
    /// Espelha a guarda de `MailStore.loadBodyIfNeeded` para a prévia não
    /// disparar viagem por uma mensagem que já tem texto — e para o teste
    /// poder afirmar isso sem uma porta de rede.
    static func needsBody(_ message: Message) -> Bool {
        message.body.isEmpty && (message.bodyHTML?.isEmpty ?? true)
    }

    static func state(for message: Message, load: MailStore.BodyLoad?) -> State {
        let corpo = message.body
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !corpo.isEmpty {
            return State(text: corpo, isWaiting: false, failure: nil)
        }

        if let html = message.bodyHTML, !html.isEmpty {
            // A mesma extração que o leitor usa quando precisa de texto de um
            // corpo HTML. Nada de `WKWebView` aqui: 380pt não são a largura de
            // um email, e o leitor cortado é a área morta que esta tela veio
            // matar.
            let texto = MimeBody.textFromHTML(html)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !texto.isEmpty {
                return State(text: texto, isWaiting: false, failure: nil)
            }
        }

        // Sem corpo ainda: o resumo segura o lugar, e o estado diz o porquê.
        let resumo = message.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        switch load {
        case .carregando:
            return State(text: resumo, isWaiting: true, failure: nil)
        case let .falhou(causa):
            return State(text: resumo, isWaiting: false, failure: causa)
        case .buscado, .none:
            return State(text: resumo, isWaiting: false, failure: nil)
        }
    }
}

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
        /// O mesmo corpo, **fatiado em blocos** por `CorpoLegivel`: é isto que
        /// a prévia desenha. `text` continua existindo para quem só precisa do
        /// texto puro (acessibilidade, testes de escolha de corpo).
        let corpo: CorpoLegivel
        /// O resumo que a análise já gravou para esta mensagem, e nada além
        /// dele: quando a análise não rodou isto é `nil`, e a prévia não
        /// desenha bloco nenhum. **Resumo em branco é resumo nenhum** — um
        /// cartão "TL;DR" vazio é pior do que não ter cartão.
        let resumo: String?
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
        let podado = message.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resumo = (podado?.isEmpty ?? true) ? nil : podado

        func pronto(_ texto: String, _ corpo: CorpoLegivel) -> State {
            State(text: texto, corpo: corpo, resumo: resumo, isWaiting: false, failure: nil)
        }

        let texto = message.body
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // O HTML **primeiro**, quando existe: é onde a estrutura está. Extrair
        // texto dele e depois tentar reconhecer a forma é jogar fora a tabela
        // do formulário e a lista da newsletter — que foi exatamente o defeito
        // das capturas. `CorpoLegivel.deHTML` guarda o que
        // `MimeBody.textFromHTML` descarta.
        //
        // Continua **sem** `WKWebView`: 380pt não são a largura de um email, e
        // o leitor cortado é a área morta que esta tela veio matar.
        if let html = message.bodyHTML, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let corpo = CorpoLegivel.deHTML(html)
            if !corpo.isEmpty {
                return pronto(texto.isEmpty ? corpo.textoVisivel : texto, corpo)
            }
        }

        if !texto.isEmpty {
            return pronto(texto, CorpoLegivel.deTextoSimples(texto))
        }

        // Sem corpo ainda: o trecho da lista segura o lugar, e o estado diz o
        // porquê.
        let trecho = message.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        let corpo = CorpoLegivel.deTextoSimples(trecho)
        switch load {
        case .carregando:
            return State(text: trecho, corpo: corpo, resumo: resumo, isWaiting: true, failure: nil)
        case let .falhou(causa):
            return State(text: trecho, corpo: corpo, resumo: resumo, isWaiting: false, failure: causa)
        case .buscado, .none:
            return State(text: trecho, corpo: corpo, resumo: resumo, isWaiting: false, failure: nil)
        }
    }
}

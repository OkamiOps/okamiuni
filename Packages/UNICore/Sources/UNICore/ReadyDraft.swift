import Foundation

/// Uma resposta já escrita, guardada antes de a pessoa pedir.
///
/// É o dado que faz o dashboard 08 dizer "A resposta já está escrita" em vez de
/// "quer que eu escreva?". Nasce da fila do UNISync (Tarefa 2) e chega aqui
/// pronta: a decisão de mostrar ou não é do `DayPlan`, e ela é pura.
///
/// **`contentHash` é a condição de validade.** Um rascunho vale para o texto que
/// ele leu, e só para ele: se a mensagem mudou — corpo baixado depois, thread
/// atualizada —, o rascunho é de outra coisa e a tela não pode oferecê-lo como
/// se fosse desta. É por isso que o hash é campo, e não a data: uma data diz
/// quando o rascunho nasceu, não sobre o quê.
public struct ReadyDraft: Sendable, Hashable, Codable {
    public let messageID: String
    public let text: String
    public let contentHash: String
    /// Quem escreveu — `Foundation Models`, o roteador remoto. Guardado porque
    /// a regravação depende dele: um modelo novo invalida o que o velho disse.
    public let modelVersion: String
    /// O rascunho olhou a agenda para propor horário. A tela escreve
    /// "Olhei sua agenda: os dois estão livres" só quando isto é `true`.
    public let usedAgenda: Bool

    public init(
        messageID: String,
        text: String,
        contentHash: String,
        modelVersion: String,
        usedAgenda: Bool = false
    ) {
        self.messageID = messageID
        self.text = text
        self.contentHash = contentHash
        self.modelVersion = modelVersion
        self.usedAgenda = usedAgenda
    }

    /// O rascunho ainda fala **desta** versão da mensagem.
    public func matches(_ message: Message) -> Bool {
        contentHash == ReadyDraft.contentHash(for: message)
    }

    /// A impressão digital do texto que o rascunho leu.
    ///
    /// FNV-1a, e não `Hasher`: `Hasher` é semeado por processo, e um hash que
    /// muda a cada abertura do app faria **todo** rascunho guardado parecer
    /// vencido no reinício seguinte. Assunto, resumo do corpo e corpo entram;
    /// leitura, estrela e pasta não — mudar de pasta não muda o que a pessoa
    /// tem a responder.
    public static func contentHash(for message: Message) -> String {
        var texto = message.subject
        texto += "\n"
        texto += message.snippet
        texto += "\n"
        texto += message.body.joined(separator: "\n")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(texto.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    /// A frase que a linha da lista mostra entre aspas.
    ///
    /// **Pula a saudação.** A primeira frase literal de um email escrito por
    /// gente é "Oi Jack," — que não diz nada sobre a resposta. Uma linha curta
    /// terminada em vírgula é saudação, não conteúdo, e o que a pessoa precisa
    /// ler antes de clicar em "Enviar" é a frase que decide.
    public var firstSentence: String {
        let linhas = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let corpo = linhas.drop { linha in
            linha.hasSuffix(",") && linha.count < 40
        }
        let texto = corpo.joined(separator: " ")
        return DayPlan.firstSentence(of: texto)
    }
}

import Foundation
import UNICore

/// A segunda chamada que a imagem embutida do Gmail exige.
///
/// **Por que ela existe.** A `messages.get` do Gmail entrega o HTML da mensagem
/// e, quase sempre, **não** entrega as imagens que esse HTML referencia por
/// `cid:`: no lugar do `body.data` vem um `attachmentId`, e a imagem só desce
/// por `users.messages.attachments.get`. Sem esta peça, todo `cid:` de conta
/// Gmail caía no vazio de 1×1 — a newsletter que é 100% imagem abria em branco,
/// e o email com uma foto no meio abria com um buraco. Era a dívida registrada
/// na M3-8, e é o defeito que o dono descreveu como "mesmo carregando as imagens
/// o OkamiUNI não mostra todas".
///
/// **Os tetos são os da M3-8, e não outros.** `MimeSanitize.tetoPorImagem` e
/// `tetoPorMensagem` decidem o que entra — conferidos **duas vezes**: contra o
/// `size` que o Gmail declara, antes de gastar a viagem, e contra o que de fato
/// chegou, que é a única medida que não depende de o servidor ter falado a
/// verdade.
public enum GmailInlineAttachments {

    /// A mensagem com as imagens embutidas resolvidas.
    ///
    /// Uma viagem para a mensagem e uma por imagem que **cabe**. A mensagem sem
    /// imagem pendente nenhuma custa exatamente o que custava antes: a lista
    /// vem vazia e nenhuma chamada extra sai.
    ///
    /// **Uma imagem que falha não derruba a mensagem.** O corpo com um buraco é
    /// muito melhor do que o leitor dizendo "não foi possível baixar" por causa
    /// de um logotipo. E as duas ausências continuam separadas: a que **não
    /// coube** sai daqui como vazio comum e nunca mais é pedida; a que falhou
    /// por rede continua marcada como pendente, e a próxima abertura tenta de
    /// novo — uma vez, como manda `MessageStore.loadBodyIfNeeded`.
    public static func message(
        _ cliente: GmailClient, id: String
    ) async throws -> GmailMessage {
        let dados = try await cliente.messageData(id: id, format: .full)
        let pendentes = try GmailMessageParser.inlinePorBuscar(dados)
        guard !pendentes.isEmpty else { return try GmailMessageParser.parse(dados) }

        var buscadas: [MimeSanitize.ImagemInline] = []
        var semConserto: [String] = []
        var gasto = 0
        for pendente in pendentes {
            // O `size` declarado é a primeira peneira: não se paga a viagem de
            // uma foto que já se sabe que não vai caber.
            guard pendente.tamanho <= MimeSanitize.tetoPorImagem,
                  gasto + pendente.tamanho <= MimeSanitize.tetoPorMensagem else {
                semConserto.append(pendente.contentID)
                continue
            }
            // A falha de rede **não** entra em `semConserto`: ela não é uma
            // decisão nossa sobre a imagem, é um dia ruim — e a próxima
            // abertura tenta outra vez.
            guard let bytes = try? await cliente.inlineAttachment(
                messageID: id, attachmentID: pendente.attachmentID
            ) else { continue }
            // E o tamanho de verdade é a segunda peneira: o `size` é a palavra
            // do servidor, e o orçamento é nosso.
            guard bytes.count <= MimeSanitize.tetoPorImagem,
                  gasto + bytes.count <= MimeSanitize.tetoPorMensagem else {
                semConserto.append(pendente.contentID)
                continue
            }
            gasto += bytes.count
            buscadas.append(MimeSanitize.ImagemInline(
                contentID: pendente.contentID, mime: pendente.mime, dados: bytes
            ))
        }
        return try GmailMessageParser.parse(
            dados, inline: buscadas, semConserto: semConserto
        )
    }
}

extension GmailClient {

    /// `users.messages.get`, crua.
    ///
    /// A `message(id:format:)` já existe e devolve `GmailMessage` — mas quem vai
    /// buscar as imagens embutidas precisa do JSON **duas vezes**: uma para
    /// saber quais faltam, outra para montar a mensagem com elas dentro. Pedir a
    /// mesma resposta ao servidor duas vezes seria uma viagem inteira a mais por
    /// mensagem aberta.
    public func messageData(id: String, format: GmailFormat) async throws -> Data {
        var itens = [URLQueryItem(name: "format", value: format.rawValue)]
        if format == .metadata {
            for nome in ["From", "To", "Cc", "Subject", "Date"] {
                itens.append(URLQueryItem(name: "metadataHeaders", value: nome))
            }
        }
        return try await getData(path: "messages/\(id)", query: itens)
    }

    /// `users.messages.attachments.get` — os bytes de **um** anexo.
    ///
    /// A resposta é `{"size": n, "data": "<base64url>"}`. O `data` vem em
    /// base64**url** (`-` e `_` no lugar de `+` e `/`), como todo corpo desta
    /// API: decodificá-lo como base64 comum devolve nulo, que viraria imagem
    /// faltando com cara de imagem grande demais.
    public func inlineAttachment(messageID: String, attachmentID: String) async throws -> Data {
        struct Wire: Decodable { let data: String? }
        let cru = try await getData(
            path: "messages/\(messageID)/attachments/\(attachmentID)", query: []
        )
        guard let fio = try? JSONDecoder().decode(Wire.self, from: cru), let texto = fio.data else {
            throw SyncError.resposta("A Gmail API devolveu um anexo sem `data`.")
        }
        guard let dados = MimeBody.base64(
            texto.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
        ) else {
            throw SyncError.resposta("O anexo veio num base64 que não conseguimos ler.")
        }
        return dados
    }
}

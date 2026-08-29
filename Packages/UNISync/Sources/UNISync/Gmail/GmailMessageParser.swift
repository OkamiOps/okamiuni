import Foundation
import UNICore

/// O JSON da `messages.get` virando `GmailMessage`.
///
/// Puro e num arquivo próprio porque é a parte que mais erra e a que mais
/// barato se testa: MIME aninhado, base64url, RFC 2047 e milissegundos. Nada
/// aqui toca rede.
public enum GmailMessageParser {
    private struct Wire: Decodable {
        struct Header: Decodable { let name: String; let value: String }
        struct Body: Decodable { let data: String? }
        struct Part: Decodable {
            let mimeType: String?
            let headers: [Header]?
            let body: Body?
            let parts: [Part]?
        }
        let id: String
        let labelIds: [String]?
        let snippet: String?
        let internalDate: String?
        let payload: Part?
    }

    public static func parse(_ data: Data) throws -> GmailMessage {
        let fio: Wire
        do {
            fio = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw SyncError.resposta("A Gmail API devolveu uma mensagem num formato que não conhecemos.")
        }
        guard let payload = fio.payload else {
            throw SyncError.resposta("A mensagem \(fio.id) veio sem `payload`.")
        }

        let cabecalhos = payload.headers ?? []
        func cabecalho(_ nome: String) -> String? {
            cabecalhos.first { $0.name.lowercased() == nome.lowercased() }?.value
        }

        // `internalDate` vem em **milissegundos** desde a época, como string.
        // Tratá-lo como segundos joga a mensagem para o ano 58 mil e a lista
        // sai fora de ordem — e como o campo é `String`, o erro compila.
        let milissegundos = Double(fio.internalDate ?? "0") ?? 0

        let corpo = corpoDe(payload)
        return GmailMessage(
            id: fio.id,
            labelIDs: fio.labelIds ?? [],
            internalDate: Date(timeIntervalSince1970: milissegundos / 1_000),
            from: MailAddress.parse(cabecalho("From") ?? "")
                ?? Contact(name: "Remetente desconhecido", address: ""),
            to: MailAddress.parseList(cabecalho("To") ?? ""),
            cc: MailAddress.parseList(cabecalho("Cc") ?? ""),
            subject: MailAddress.decodeRFC2047(cabecalho("Subject") ?? ""),
            snippet: fio.snippet ?? "",
            body: corpo.paragraphs,
            html: corpo.html,
            calendarICS: corpo.calendar
        )
    }

    /// O corpo da mensagem do Gmail nas três formas que o app guarda.
    ///
    /// A árvore da API é outra (JSON, base64url, `mimeType` por nó), mas as
    /// **decisões** são as mesmas do MIME cru, e é por isso que elas moram lá:
    /// a limpeza do HTML e os tetos das imagens embutidas são de `MimeSanitize`,
    /// não uma segunda opinião escrita aqui.
    ///
    /// **Dívida conhecida:** a imagem embutida do Gmail quase sempre vem como
    /// `attachmentId` em vez de `body.data` — quem a quiser inteira precisa de
    /// outra chamada à API. As que já vêm com `data` são embutidas; as outras
    /// caem no vazio de 1×1 de `MimeSanitize.placeholder`, como qualquer `cid:`
    /// órfão. Está registrado no relatório da M3-8.
    private static func corpoDe(_ payload: Wire.Part) -> MimeBody.Decoded {
        let plano = firstPart(in: payload, mimeType: "text/plain")
        let html = firstPart(in: payload, mimeType: "text/html")
        let agenda = firstPart(in: payload, mimeType: "text/calendar")
            ?? firstPart(in: payload, mimeType: "application/ics")

        let texto: String
        if let plano {
            texto = plano
        } else if let html {
            texto = MimeBody.textFromHTML(html)
        } else {
            texto = ""
        }
        return MimeBody.Decoded(
            text: texto,
            html: html.flatMap {
                MimeSanitize.sanitize(html: $0, imagens: imagensInline(in: payload))
            },
            calendar: agenda
        )
    }

    /// As imagens que a própria mensagem carrega, na ordem do documento.
    private static func imagensInline(in part: Wire.Part) -> [MimeSanitize.ImagemInline] {
        var achadas: [MimeSanitize.ImagemInline] = []
        let mime = part.mimeType?.lowercased() ?? ""
        if mime.hasPrefix("image/"),
           let id = part.headers?.first(where: { $0.name.lowercased() == "content-id" })?.value,
           let dado = part.body?.data,
           let dados = MimeBody.base64(
               dado.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
           ) {
            achadas.append(.init(contentID: id, mime: mime, dados: dados))
        }
        for filha in part.parts ?? [] { achadas += imagensInline(in: filha) }
        return achadas
    }

    /// A primeira parte de um tipo, em profundidade, já decodificada.
    private static func firstPart(in part: Wire.Part, mimeType: String) -> String? {
        if part.mimeType?.lowercased() == mimeType, let dado = part.body?.data {
            // O `charset=` é do cabeçalho **da parte**, e ignorá-lo já trocava
            // todo `é` de um remetente latin1 por um losango de substituição.
            let tipo = part.headers?.first { $0.name.lowercased() == "content-type" }?.value
            return decodeBody(base64URL: dado, contentType: tipo)
        }
        for filha in part.parts ?? [] {
            if let texto = firstPart(in: filha, mimeType: mimeType) { return texto }
        }
        return nil
    }

    /// base64**url**: `-` e `_` no lugar de `+` e `/`, e sem padding.
    ///
    /// `Data(base64Encoded:)` recusa os dois desvios e devolve `nil` — que,
    /// engolido, viraria corpo vazio em toda mensagem acentuada.
    ///
    /// - Parameter contentType: o cabeçalho da parte, para o `charset=`. Nulo
    ///   é UTF-8, que é o que a Gmail API entrega na esmagadora maioria.
    public static func decodeBody(base64URL: String, contentType: String? = nil) -> String {
        let texto = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let dados = MimeBody.base64(texto) else { return "" }
        return MimeBody.string(de: dados, charset: MimeBody.charset(de: contentType ?? ""))
    }

    /// Parágrafos: linhas em branco separam, pontas somem.
    ///
    /// Quebra simples **não** separa — um parágrafo com quebra de 78 colunas
    /// (que é o que todo cliente de email produz) viraria doze parágrafos de
    /// uma linha, e o leitor desenharia um espaço entre cada uma.
    public static func paragraphs(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

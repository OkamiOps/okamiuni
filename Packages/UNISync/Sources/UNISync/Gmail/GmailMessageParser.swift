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
            body: paragraphs(from: plainText(in: payload) ?? "")
        )
    }

    /// A primeira parte `text/plain` da árvore MIME, em profundidade.
    ///
    /// **Texto, nunca HTML**: o leitor do Marco 1 desenha `[String]` de
    /// parágrafos, e entregar a parte HTML encheria a tela de tags.
    private static func plainText(in part: Wire.Part) -> String? {
        if part.mimeType?.lowercased() == "text/plain", let dado = part.body?.data {
            return decodeBody(base64URL: dado)
        }
        for filha in part.parts ?? [] {
            if let texto = plainText(in: filha) { return texto }
        }
        // Uma mensagem só de HTML não tem texto para nós. Vazio é a resposta
        // honesta: o corpo por demanda do Marco 3 é quem resolve isso.
        return nil
    }

    /// base64**url**: `-` e `_` no lugar de `+` e `/`, e sem padding.
    ///
    /// `Data(base64Encoded:)` recusa os dois desvios e devolve `nil` — que,
    /// engolido, viraria corpo vazio em toda mensagem acentuada.
    public static func decodeBody(base64URL: String) -> String {
        var texto = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let sobra = texto.count % 4
        if sobra > 0 { texto += String(repeating: "=", count: 4 - sobra) }
        guard let dados = Data(base64Encoded: texto) else { return "" }
        return String(data: dados, encoding: .utf8) ?? ""
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

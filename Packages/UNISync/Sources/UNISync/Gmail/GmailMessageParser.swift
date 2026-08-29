import Foundation
import UNICore

/// O JSON da `messages.get` virando `GmailMessage`.
///
/// Puro e num arquivo próprio porque é a parte que mais erra e a que mais
/// barato se testa: MIME aninhado, base64url, RFC 2047 e milissegundos. Nada
/// aqui toca rede.
public enum GmailMessageParser {
    /// Uma imagem embutida que a mensagem **tem** e que a `messages.get` não
    /// entregou: o Gmail devolve `attachmentId` no lugar do `data`, e quem a
    /// quiser inteira precisa de uma segunda chamada
    /// (`users.messages.attachments.get`).
    public struct InlinePorBuscar: Sendable, Equatable {
        /// O `Content-ID` **sem** os sinais de menor e maior — a mesma chave que
        /// `MimeSanitize.normalizaContentID` produz.
        public let contentID: String
        public let mime: String
        public let attachmentID: String
        /// O tamanho que o Gmail declarou, em bytes. É contra ele que o teto por
        /// imagem é conferido **antes** da viagem: não se baixa meio megabyte
        /// para o jogar fora ao chegar.
        public let tamanho: Int

        public init(contentID: String, mime: String, attachmentID: String, tamanho: Int) {
            self.contentID = contentID
            self.mime = mime
            self.attachmentID = attachmentID
            self.tamanho = tamanho
        }
    }

    private struct Wire: Decodable {
        struct Header: Decodable { let name: String; let value: String }
        struct Body: Decodable {
            let data: String?
            let attachmentId: String?
            let size: Int?
        }
        struct Part: Decodable {
            let mimeType: String?
            let headers: [Header]?
            let body: Body?
            let parts: [Part]?
        }
        let id: String
        let threadId: String?
        let labelIds: [String]?
        let snippet: String?
        let internalDate: String?
        let payload: Part?
    }

    /// As imagens embutidas que esta resposta **tem e não entregou**.
    ///
    /// Pura, e separada de `parse`, porque a decisão de ir buscá-las é de quem
    /// tem rede — ver `GmailInlineAttachments`. Aqui só se diz quais são, qual o
    /// `Content-ID` de cada uma e quanto o servidor disse que ela pesa.
    public static func inlinePorBuscar(_ data: Data) throws -> [InlinePorBuscar] {
        guard let fio = try? JSONDecoder().decode(Wire.self, from: data),
              let payload = fio.payload else { return [] }
        return porBuscar(in: payload)
    }

    /// - Parameters:
    ///   - inline: imagens embutidas já buscadas por fora (o `attachments.get`
    ///     do Gmail). Elas entram no lugar das pendentes — ver
    ///     `MimeSanitize.embute(_:pendentes:)`.
    ///   - semConserto: os `Content-ID` que quem buscou decidiu **não** buscar,
    ///     e que não vão mudar de ideia: a foto que já se sabe grande demais
    ///     para o teto da M3-8. Elas caem no vazio comum, sem a marca de
    ///     pendente — pedi-las de novo seria uma viagem por abertura, para
    ///     sempre. A que falhou por rede **não** entra aqui: essa vale retentar.
    public static func parse(
        _ data: Data,
        inline resolvidas: [MimeSanitize.ImagemInline] = [],
        semConserto: [String] = []
    ) throws -> GmailMessage {
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

        // A corrente da conversa: `References` quando existe, e `In-Reply-To`
        // sozinho quando é só o que veio — que é o caso de todo cliente que
        // manda um sem o outro, e são muitos.
        let corrente = ThreadKey.ids(inHeader: cabecalho("References") ?? "")
        let respondendo = ThreadKey.ids(inHeader: cabecalho("In-Reply-To") ?? "")

        let corpo = corpoDe(payload, resolvidas: resolvidas, semConserto: semConserto)
        return GmailMessage(
            id: fio.id,
            threadID: fio.threadId ?? "",
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
            calendarICS: corpo.calendar,
            rfcMessageID: ThreadKey.ids(inHeader: cabecalho("Message-ID") ?? "").first,
            references: corrente.isEmpty ? respondendo : corrente
        )
    }

    /// O corpo da mensagem do Gmail nas três formas que o app guarda.
    ///
    /// A árvore da API é outra (JSON, base64url, `mimeType` por nó), mas as
    /// **decisões** são as mesmas do MIME cru, e é por isso que elas moram lá:
    /// a limpeza do HTML e os tetos das imagens embutidas são de `MimeSanitize`,
    /// não uma segunda opinião escrita aqui.
    ///
    /// **A dívida da M3-8, paga na M3-18.** A imagem embutida do Gmail quase
    /// sempre vem como `attachmentId` em vez de `body.data`, e quem a quiser
    /// inteira precisa de outra chamada à API. Antes disto ela caía no vazio de
    /// 1×1 e a newsletter que é só imagem abria **em branco** — o defeito que o
    /// dono viu. Agora: as que já vêm com `data` são embutidas aqui; as que só
    /// têm `attachmentId` são anunciadas por `inlinePorBuscar` e entram como
    /// `placeholderPendente` até alguém com rede as trazer em `resolvidas` (ver
    /// `GmailInlineAttachments`).
    private static func corpoDe(
        _ payload: Wire.Part,
        resolvidas: [MimeSanitize.ImagemInline] = [],
        semConserto: [String] = []
    ) -> MimeBody.Decoded {
        let plano = firstPart(in: payload, mimeType: "text/plain").map(desdobra)
        let html = firstPart(in: payload, mimeType: "text/html")?.texto
        let agenda = (firstPart(in: payload, mimeType: "text/calendar")
            ?? firstPart(in: payload, mimeType: "application/ics"))?.texto

        let texto: String
        if let plano {
            texto = plano
        } else if let html {
            texto = MimeBody.textFromHTML(html)
        } else {
            texto = ""
        }
        let descartadas = Set(semConserto.map(MimeSanitize.normalizaContentID))
        return MimeBody.Decoded(
            text: texto,
            html: html.flatMap {
                MimeSanitize.sanitize(
                    html: $0,
                    // As já buscadas primeiro: com o mesmo `Content-ID`, é a que
                    // tem bytes que vale.
                    imagens: resolvidas + imagensInline(in: payload),
                    // Fica pendente só o que ninguém resolveu **e** ninguém
                    // descartou de vez.
                    pendentes: porBuscar(in: payload).map(\.contentID).filter {
                        !descartadas.contains($0)
                    }
                )
            },
            calendar: agenda
        )
    }

    /// As imagens embutidas que só têm `attachmentId`, na ordem do documento.
    ///
    /// Sem `Content-ID` não entra: uma imagem que o HTML não referencia por
    /// `cid:` é anexo, não é parte do desenho — buscá-la seria baixar o PDF de
    /// uma nota fiscal para não a mostrar em lugar nenhum.
    private static func porBuscar(in part: Wire.Part) -> [InlinePorBuscar] {
        var achadas: [InlinePorBuscar] = []
        let mime = part.mimeType?.lowercased() ?? ""
        if mime.hasPrefix("image/"),
           part.body?.data == nil,
           let anexo = part.body?.attachmentId,
           let id = part.headers?.first(where: { $0.name.lowercased() == "content-id" })?.value {
            achadas.append(InlinePorBuscar(
                contentID: MimeSanitize.normalizaContentID(id), mime: mime,
                attachmentID: anexo, tamanho: part.body?.size ?? 0
            ))
        }
        for filha in part.parts ?? [] { achadas += porBuscar(in: filha) }
        return achadas
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

    /// Uma parte já decodificada, com o `Content-Type` dela ao lado.
    ///
    /// O cabeçalho vem junto porque ele ainda decide coisa: o `charset=` (que
    /// `decodeBody` já lê) e o `format=flowed` do RFC 3676, que diz se as
    /// quebras de linha daquela parte são do autor ou do transporte.
    struct Parte {
        let texto: String
        let tipo: String
    }

    /// A primeira parte de um tipo, em profundidade, já decodificada.
    private static func firstPart(in part: Wire.Part, mimeType: String) -> Parte? {
        if part.mimeType?.lowercased() == mimeType, let dado = part.body?.data {
            // O `charset=` é do cabeçalho **da parte**, e ignorá-lo já trocava
            // todo `é` de um remetente latin1 por um losango de substituição.
            let tipo = part.headers?.first { $0.name.lowercased() == "content-type" }?.value
            return Parte(
                texto: decodeBody(base64URL: dado, contentType: tipo), tipo: tipo ?? ""
            )
        }
        for filha in part.parts ?? [] {
            if let achada = firstPart(in: filha, mimeType: mimeType) { return achada }
        }
        return nil
    }

    /// A parte de texto com as quebras do `format=flowed` desfeitas — quando o
    /// remetente as declarou. É a mesma decisão de `MimeBody.desdobra`, tomada
    /// no mesmo lugar da árvore: quem lê o cabeçalho da parte.
    private static func desdobra(_ parte: Parte) -> String {
        guard MimeBody.parametro("format", em: parte.tipo)?.lowercased() == "flowed" else {
            return parte.texto
        }
        let delSp = MimeBody.parametro("delsp", em: parte.tipo)?.lowercased() == "yes"
        return PlainTextReflow.reflow(parte.texto, flowed: true, delSp: delSp)
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

import Foundation
import UNICore

public struct GmailSendAs: Sendable, Hashable {
    public let email: String
    public let displayName: String
    public let isPrimary: Bool
    public let isDefault: Bool

    public init(email: String, displayName: String, isPrimary: Bool, isDefault: Bool) {
        self.email = email
        self.displayName = displayName
        self.isPrimary = isPrimary
        self.isDefault = isDefault
    }
}

public struct GmailProfile: Sendable, Hashable {
    public let emailAddress: String
    /// O ponto de partida do sync incremental do Marco 3. Guardado já aqui,
    /// na carga inicial: capturá-lo depois abriria uma janela em que as
    /// mensagens chegadas no meio nunca apareceriam.
    public let historyID: String
}

public struct GmailLabel: Sendable, Hashable {
    public let id: String
    public let name: String
    /// `"system"` ou `"user"`, como a API os classifica.
    ///
    /// Existe desde a M3-17 porque a barra lateral precisa separar os dois: os
    /// rótulos do usuário são **todos** pastas, e os do sistema quase nenhum é
    /// — `UNREAD`, `STARRED`, `IMPORTANT` e as `CATEGORY_*` são estados e abas,
    /// não lugares. Ver `GmailFolders`.
    ///
    /// Padrão `"user"` no `init` para o campo ser aditivo: os testes que
    /// montavam um rótulo com id e nome continuam valendo.
    public let type: String
    /// Só no `labels.get`. A listagem não traz total; `nil` é "ainda não pedimos".
    public let messagesTotal: Int?

    public init(id: String, name: String, type: String = "user", messagesTotal: Int? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.messagesTotal = messagesTotal
    }
}

public struct GmailPage: Sendable, Hashable {
    public let ids: [String]
    public let nextPageToken: String?
    public let resultSizeEstimate: Int?

    public init(ids: [String], nextPageToken: String?, resultSizeEstimate: Int? = nil) {
        self.ids = ids
        self.nextPageToken = nextPageToken
        self.resultSizeEstimate = resultSizeEstimate
    }
}

public enum GmailFormat: String, Sendable {
    /// Cabeçalhos e nada de corpo — o que a lista precisa.
    case metadata
    /// A mensagem inteira.
    case full
}

public struct GmailMessage: Sendable, Hashable {
    public struct Attachment: Sendable, Hashable {
        public let attachmentID: String?
        public let filename: String
        public let mimeType: String
        public let byteCount: Int
        /// Algumas respostas pequenas trazem os bytes no próprio payload. As
        /// maiores trazem só `attachmentId`, que só será baixado ao salvar.
        public let inlineData: Data?

        public init(
            attachmentID: String?, filename: String, mimeType: String,
            byteCount: Int, inlineData: Data? = nil
        ) {
            self.attachmentID = attachmentID
            self.filename = AttachmentName.sanitize(filename)
            self.mimeType = AttachmentName.mimeType(mimeType)
            self.byteCount = max(0, byteCount)
            self.inlineData = inlineData
        }
    }
    public let id: String
    /// A conversa **segundo o Gmail**.
    ///
    /// Ele já vinha em toda resposta da API e era jogado fora; agora é a chave
    /// da conversa, sem discussão — o Gmail resolveu o agrupamento com mais
    /// informação do que temos aqui (ele vê a caixa inteira, não só os 90 dias
    /// que baixamos), e refazer a conta pelos cabeçalhos daria uma resposta
    /// diferente da que a pessoa lê no webmail.
    ///
    /// Vazio é o caso torto — resposta sem o campo —, e aí a derivação cai nos
    /// cabeçalhos como qualquer conta IMAP.
    public let threadID: String
    public let labelIDs: [String]
    public let internalDate: Date
    public let from: Contact
    public let to: [Contact]
    public let cc: [Contact]
    public let subject: String
    public let snippet: String
    /// Vazio em formato `metadata` — ausência legítima, não erro.
    public let body: [String]
    /// O HTML sanitizado da mensagem, quando ela tem uma parte `text/html`.
    /// `nil` em formato `metadata` e nas mensagens só-texto.
    public let html: String?
    /// O `text/calendar` cru do convite, quando houver.
    public let calendarICS: String?
    /// O cabeçalho `Message-ID`, sem `<>`. Vem em `metadata` e em `full` — a
    /// API manda os cabeçalhos nos dois formatos.
    public let rfcMessageID: String?
    /// `References` (ou `In-Reply-To`, quando é só o que veio), sem `<>`, da
    /// raiz para cá.
    ///
    /// A conversa do Gmail não depende deles — quem manda é o `threadId` —,
    /// mas a **resposta que sai daqui** depende: é com isto que o composer
    /// escreve `In-Reply-To` e `References`, e é o que faz a resposta cair na
    /// conversa certa na caixa de quem recebe.
    public let references: [String]
    /// Arquivos recebidos, com bytes só quando o Gmail os trouxe no payload.
    public let attachments: [Attachment]

    public init(
        id: String, threadID: String, labelIDs: [String], internalDate: Date,
        from: Contact, to: [Contact], cc: [Contact], subject: String,
        snippet: String, body: [String], html: String?, calendarICS: String?,
        rfcMessageID: String?, references: [String], attachments: [Attachment] = []
    ) {
        self.id = id
        self.threadID = threadID
        self.labelIDs = labelIDs
        self.internalDate = internalDate
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.snippet = snippet
        self.body = body
        self.html = html
        self.calendarICS = calendarICS
        self.rfcMessageID = rfcMessageID
        self.references = references
        self.attachments = attachments
    }
}

/// Cabeçalhos de endereço, do jeito que eles chegam de verdade.
public enum MailAddress {
    /// `"Duarte, Marina" <marina@x.com>` → nome e endereço separados.
    ///
    /// Sem nome, o **endereço** vira o nome: uma linha da lista com o campo de
    /// remetente em branco é pior do que uma com o endereço cru.
    public static func parse(_ header: String) -> Contact? {
        let limpo = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty else { return nil }

        if let abre = limpo.lastIndex(of: "<"), let fecha = limpo.lastIndex(of: ">"), abre < fecha {
            let endereco = String(limpo[limpo.index(after: abre)..<fecha])
                .trimmingCharacters(in: .whitespaces)
            var nome = String(limpo[limpo.startIndex..<abre])
                .trimmingCharacters(in: .whitespaces)
            if nome.hasPrefix("\""), nome.hasSuffix("\""), nome.count >= 2 {
                nome = String(nome.dropFirst().dropLast())
            }
            nome = decodeRFC2047(nome)
            guard !endereco.isEmpty else { return nil }
            return Contact(name: nome.isEmpty ? endereco : nome, address: endereco)
        }
        return Contact(name: limpo, address: limpo)
    }

    /// A lista de `To`/`Cc`, cortada por vírgula **fora das aspas**.
    ///
    /// Cortar por vírgula sem olhar as aspas parte `"Duarte, Marina"` em dois
    /// destinatários, e o "Responder a todos" passa a mandar email para
    /// alguém chamado "Duarte".
    public static func parseList(_ header: String) -> [Contact] {
        var partes: [String] = []
        var atual = ""
        var dentroDeAspas = false
        for caractere in header {
            switch caractere {
            case "\"": dentroDeAspas.toggle(); atual.append(caractere)
            case "," where !dentroDeAspas: partes.append(atual); atual = ""
            default: atual.append(caractere)
            }
        }
        partes.append(atual)
        return partes.compactMap(parse)
    }

    /// `=?UTF-8?B?…?=` e `=?UTF-8?Q?…?=` (RFC 2047).
    ///
    /// O Foundation não traz isto pronto, e sem ele todo assunto acentuado
    /// aparece como uma linha de gibberish na lista — que é a primeira coisa
    /// que se vê ao conectar uma conta em português.
    ///
    /// **A leitura segue a gramática, não a busca de texto.** Procurar o `?=`
    /// de fechamento a partir do `=?` de abertura parece bastar até a carga Q
    /// começar com `=` — o caso de qualquer acento nosso, porque `ç` é `=C3=A7`.
    /// Aí o primeiro `?=` encontrado é o `?` que fecha o token de codificação
    /// somado ao `=` que abre o primeiro octeto, e o assunto sai picado ao meio
    /// (`configura=?UTF-8?Q?=C3=A7…` virava `configura UTF-8?QC3=A7…`). Por isso
    /// aqui se avança pelos DOIS `?` que separam charset e codificação antes de
    /// procurar o terminador: a carga tem `=` à vontade, mas nenhum `?`.
    static func decodeRFC2047(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        var resultado = ""
        var resto = Substring(text)
        var anteriorFoiCodificada = false
        while let inicio = resto.range(of: "=?") {
            let literal = resto[resto.startIndex..<inicio.lowerBound]
            guard let palavra = lerPalavraCodificada(resto[inicio.lowerBound...]),
                  let encoding = encodingDeCharset(palavra.charset),
                  let texto = decodificarCarga(palavra, encoding: encoding) else {
                // Não é uma palavra codificada que saibamos ler (charset
                // desconhecido, `?=` que nunca vem, codificação estranha): o
                // `=?` é texto comum e o resto da linha segue intacto.
                resultado += resto[resto.startIndex..<inicio.upperBound]
                resto = resto[inicio.upperBound...]
                anteriorFoiCodificada = false
                continue
            }
            // O espaço que separa duas palavras codificadas não é conteúdo — é
            // só a dobra permitida pela RFC — e por isso desaparece.
            let colar = anteriorFoiCodificada && !literal.isEmpty && literal.allSatisfy(\.isWhitespace)
            if !colar { resultado += literal }
            resultado += texto
            resto = resto[palavra.fim...]
            anteriorFoiCodificada = true
        }
        resultado += resto
        return resultado
    }

    /// Uma `=?charset?codificação?carga?=` já separada em seus quatro campos.
    private struct PalavraCodificada {
        let charset: String
        let codificacao: String
        let carga: String
        /// Índice logo depois do `?=` de fechamento.
        let fim: String.Index
    }

    /// Lê a palavra codificada que começa em `trecho` (que abre com `=?`).
    private static func lerPalavraCodificada(_ trecho: Substring) -> PalavraCodificada? {
        let apos = trecho.index(trecho.startIndex, offsetBy: 2)
        guard let fimCharset = trecho[apos...].firstIndex(of: "?") else { return nil }
        let aposCharset = trecho.index(after: fimCharset)
        guard let fimCodificacao = trecho[aposCharset...].firstIndex(of: "?") else { return nil }
        let inicioCarga = trecho.index(after: fimCodificacao)
        // A carga não contém `?`: o próximo é o do terminador, e o caractere
        // seguinte tem de ser o `=`.
        guard let fimCarga = trecho[inicioCarga...].firstIndex(of: "?") else { return nil }
        let igual = trecho.index(after: fimCarga)
        guard igual < trecho.endIndex, trecho[igual] == "=" else { return nil }

        let charset = trecho[apos..<fimCharset]
        let codificacao = trecho[aposCharset..<fimCodificacao]
        let carga = trecho[inicioCarga..<fimCarga]
        guard !charset.isEmpty, codificacao.count == 1 else { return nil }
        // Palavra codificada não tem espaço em lugar nenhum; se tem, é texto
        // comum que por acaso parece uma.
        guard !charset.contains(where: \.isWhitespace), !carga.contains(where: \.isWhitespace)
        else { return nil }
        return PalavraCodificada(
            charset: String(charset),
            codificacao: String(codificacao).uppercased(),
            carga: String(carga),
            fim: trecho.index(after: igual)
        )
    }

    /// `nil` para charset que não sabemos ler — melhor devolver o cabeçalho
    /// original do que inventar octetos e mostrar lixo na lista.
    private static func encodingDeCharset(_ charset: String) -> String.Encoding? {
        let nome = charset.uppercased()
        switch nome {
        case "UTF-8", "UTF8", "US-ASCII", "ASCII", "ANSI_X3.4-1968": return .utf8
        case "WINDOWS-1252", "CP1252": return .windowsCP1252
        default: return nome.hasPrefix("ISO-8859") ? .isoLatin1 : nil
        }
    }

    /// A variante "Q" daqui é a de cabeçalho, onde `_` vale espaço; a
    /// implementação mora em `MimeBody`, junto com a do corpo (RFC 2045), para
    /// que a correção de um escape mal-formado valha nos dois lugares.
    private static func decodificarCarga(
        _ palavra: PalavraCodificada, encoding: String.Encoding
    ) -> String? {
        switch palavra.codificacao {
        case "B":
            guard let dados = Data(base64Encoded: palavra.carga, options: [.ignoreUnknownCharacters])
            else { return nil }
            return String(data: dados, encoding: encoding)
        case "Q":
            let dados = MimeBody.quotedPrintable(palavra.carga, sublinhadoEhEspaco: true)
            return String(data: dados, encoding: encoding)
        default:
            return nil
        }
    }
}

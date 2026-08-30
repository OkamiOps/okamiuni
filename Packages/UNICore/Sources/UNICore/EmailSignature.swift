import Foundation

/// Um recurso de imagem que viaja dentro da própria assinatura de e-mail.
///
/// O recurso já vem em bytes locais. Não há URL, caminho de arquivo nem
/// carregador aqui de propósito: montar uma assinatura jamais pode disparar
/// uma requisição de rede, ler um arquivo que a pessoa não escolheu ou deixar
/// o cliente de e-mail buscar uma imagem remota ao abrir a mensagem.
public struct InlineSignatureResource: Codable, Sendable, Hashable, Identifiable {
    /// O teto é menor que o de anexos normais porque logo e foto de assinatura
    /// não devem transformar a fila local em um depósito de arquivos.
    public static let maximumByteCount = 2 * 1_024 * 1_024

    /// Tipos de imagem seguros e amplamente aceitos por clientes de e-mail.
    /// SVG fica deliberadamente de fora: além de ser um formato ativo, muitos
    /// clientes o bloqueiam ou o tratam de maneiras incompatíveis.
    public static let supportedMIMETypes: Set<String> = [
        "image/png", "image/jpeg", "image/gif", "image/webp"
    ]

    /// Identidade usada tanto em `cid:` no HTML como em `Content-ID` no MIME.
    /// Ela não contém aspas, espaço, CR/LF ou qualquer outro caractere que
    /// pudesse criar um cabeçalho MIME novo.
    public let contentID: String
    public var id: String { contentID }
    public let mimeType: String
    public let data: Data

    public init(
        contentID: String = Self.newContentID(),
        mimeType: String,
        data: Data
    ) throws {
        let normalizado = mimeType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeContentID(contentID) else {
            throw EmailSignatureError.unsafeContentID
        }
        guard Self.supportedMIMETypes.contains(normalizado) else {
            throw EmailSignatureError.unsupportedImageType(mimeType)
        }
        guard !data.isEmpty else { throw EmailSignatureError.emptyInlineResource }
        guard data.count <= Self.maximumByteCount else {
            throw EmailSignatureError.inlineResourceTooLarge(limit: Self.maximumByteCount)
        }
        self.contentID = contentID
        self.mimeType = normalizado
        self.data = data
    }

    /// Um Content-ID novo e seguro para ser usado em `src="cid:..."`.
    public static func newContentID() -> String {
        "okamiuni-\(UUID().uuidString.lowercased())@inline.local"
    }

    /// A referência que entra no HTML. Os bytes continuam fora do HTML e vão
    /// para a parte `multipart/related` quando a mensagem é enviada.
    public var cidURL: String { "cid:\(contentID)" }

    /// A validação é pública para a camada que recebe um drop/paste poder
    /// recusar cedo um ID que não seria seguro como cabeçalho.
    public static func isSafeContentID(_ value: String) -> Bool {
        guard value.utf8.count <= 128, !value.isEmpty,
              value.unicodeScalars.allSatisfy({ $0.isASCII })
        else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        let localAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+-")
        let domainAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        return parts[0].unicodeScalars.allSatisfy(localAllowed.contains)
            && parts[1].unicodeScalars.allSatisfy(domainAllowed.contains)
            && !parts[1].hasPrefix(".")
            && !parts[1].hasSuffix(".")
            && !parts[1].contains("..")
    }
}

/// Erros de validação da assinatura rica. A UI pode apresentá-los antes de a
/// assinatura entrar no banco ou numa operação de envio.
public enum EmailSignatureError: Error, Sendable, Equatable, LocalizedError {
    case plainTextTooLarge(limit: Int)
    case htmlTooLarge(limit: Int)
    case tooManyInlineResources(limit: Int)
    case inlineResourcesTooLarge(limit: Int)
    case duplicateContentID
    case unsafeContentID
    case unsupportedImageType(String)
    case emptyInlineResource
    case inlineResourceTooLarge(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .plainTextTooLarge: "O texto da assinatura é grande demais."
        case .htmlTooLarge: "O HTML da assinatura é grande demais."
        case .tooManyInlineResources: "A assinatura tem imagens demais."
        case .inlineResourcesTooLarge: "As imagens da assinatura ocupam espaço demais."
        case .duplicateContentID: "Cada imagem da assinatura precisa de um Content-ID único."
        case .unsafeContentID: "O Content-ID da imagem não é seguro."
        case .unsupportedImageType(let type): "O tipo de imagem \(type) não é aceito na assinatura."
        case .emptyInlineResource: "A imagem da assinatura está vazia."
        case .inlineResourceTooLarge: "A imagem da assinatura é grande demais."
        }
    }
}

/// A assinatura de uma conta, pronta para sobreviver na fila e no banco.
///
/// `plainText` existe sempre, mesmo quando a assinatura tem HTML: clientes
/// texto, filtros e buscas continuam recebendo uma alternativa legível. O
/// HTML pode referenciar recursos incorporados por `cid:` e imagens públicas
/// por `https:`. Os últimos preservam a assinatura que a pessoa importou, mas
/// o cliente de e-mail do destinatário decide se os carrega. URL `http:`,
/// `file:`, `javascript:` e `data:` nunca sobrevivem à sanitização.
public struct EmailSignature: Codable, Sendable, Hashable {
    public static let maximumPlainTextByteCount = 24 * 1_024
    public static let maximumHTMLByteCount = 128 * 1_024
    public static let maximumInlineResourceCount = 8
    public static let maximumInlineResourceByteCount = 5 * 1_024 * 1_024

    public let plainText: String
    /// `nil` quando a assinatura é só texto; string não-vazia quando há HTML
    /// seguro para a parte rica de uma mensagem.
    public let html: String?
    public let inlineResources: [InlineSignatureResource]

    /// Ponte explícita da assinatura antiga em texto simples.
    public init(legacyText: String) {
        plainText = Self.sanitizePlainText(legacyText)
        html = nil
        inlineResources = []
    }

    /// Cria uma assinatura rica e aplica os limites antes de ela alcançar o
    /// banco. HTML inseguro é limpo, em vez de virar um recurso que a UI não
    /// consegue editar depois; dados estruturalmente inválidos ainda lançam um
    /// erro claro para quem importou/criou a imagem.
    public init(
        plainText: String,
        html: String? = nil,
        inlineResources: [InlineSignatureResource] = []
    ) throws {
        let plain = Self.sanitizePlainText(plainText)
        guard plain.utf8.count <= Self.maximumPlainTextByteCount else {
            throw EmailSignatureError.plainTextTooLarge(limit: Self.maximumPlainTextByteCount)
        }
        guard inlineResources.count <= Self.maximumInlineResourceCount else {
            throw EmailSignatureError.tooManyInlineResources(limit: Self.maximumInlineResourceCount)
        }
        let contentIDs = inlineResources.map(\.contentID)
        guard Set(contentIDs).count == contentIDs.count else {
            throw EmailSignatureError.duplicateContentID
        }
        guard inlineResources.reduce(0, { $0 + $1.data.count }) <= Self.maximumInlineResourceByteCount else {
            throw EmailSignatureError.inlineResourcesTooLarge(limit: Self.maximumInlineResourceByteCount)
        }
        if let html, html.utf8.count > Self.maximumHTMLByteCount {
            throw EmailSignatureError.htmlTooLarge(limit: Self.maximumHTMLByteCount)
        }

        let sanitizedHTML = Self.sanitizedHTML(html, inlineResources: inlineResources)
        self.plainText = plain.isEmpty
            ? Self.plainTextFallback(from: sanitizedHTML)
            : plain
        self.html = sanitizedHTML
        self.inlineResources = sanitizedHTML == nil ? [] : inlineResources
    }

    /// Sanitiza HTML de assinatura com os mesmos Content-IDs que a mensagem
    /// aceitará. É público para preview/importação na UI; construtores e
    /// decodificação também passam por ele, portanto usá-lo não é obrigatório
    /// para manter o dado seguro.
    public static func sanitizedHTML(
        _ html: String?, inlineResources: [InlineSignatureResource] = []
    ) -> String? {
        guard var result = html?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else {
            return nil
        }
        // Não permitir controles no documento impede que uma atribuição possa
        // se tornar um cabeçalho ou URL diferente depois de serializada.
        result.unicodeScalars.removeAll { $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t" }

        // Tags ativas ou capazes de carregar outro documento nunca fazem parte
        // de assinatura. A remoção inclui o conteúdo para não deixar script ou
        // SVG como texto acidentalmente executável em outro renderer.
        result = replacing(
            result,
            pattern: #"<(script|iframe|object|embed|svg|style|video|audio|source|link|meta|base)\b[^>]*>.*?</\1\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators], with: ""
        )
        result = replacing(
            result,
            pattern: #"<(script|iframe|object|embed|svg|style|video|audio|source|link|meta|base)\b[^>]*?/?>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators], with: ""
        )
        // Eventos HTML e CSS com `url(...)` são os dois caminhos que fariam a
        // renderização buscar algo que não foi escolhido localmente. Uma URL
        // HTTPS é aceita exclusivamente como `src` de uma imagem, abaixo.
        result = replacing(
            result,
            pattern: #"\s+on[a-z0-9_-]+\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)"#,
            options: [.caseInsensitive], with: ""
        )
        result = replacing(
            result,
            pattern: #"url\s*\(\s*[^)]*\)"#,
            options: [.caseInsensitive], with: ""
        )
        result = replacing(
            result,
            pattern: #"\s+(?:srcset|background)\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)"#,
            options: [.caseInsensitive], with: ""
        )
        // Links continuam úteis numa assinatura, mas os esquemas executáveis e
        // os caminhos locais não. `https:`/`mailto:` não são baixados pela
        // composição: são apenas links que o destinatário decide abrir.
        result = replacing(
            result,
            pattern: #"\s+href\s*=\s*(?:\"\s*(?:javascript|data|file)\s*:[^\"]*\"|'\s*(?:javascript|data|file)\s*:[^']*'|(?:javascript|data|file)\s*:[^\s>]+)"#,
            options: [.caseInsensitive], with: ""
        )

        let allowed = Set(inlineResources.map(\.contentID))
        guard let imageRegex = try? NSRegularExpression(
            pattern: #"<img\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let matches = imageRegex.matches(
            in: result, range: NSRange(result.startIndex..., in: result)
        )
        // Trocar de trás para frente mantém os ranges originais válidos.
        for match in matches.reversed() {
            guard let wholeRange = Range(match.range, in: result) else { continue }
            let originalTag = String(result[wholeRange])
            guard let originalSource = attribute(named: "src", in: originalTag) else {
                result.removeSubrange(wholeRange)
                continue
            }
            let source = originalSource.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeSource: String?
            if source.count >= 4, source.prefix(4).lowercased() == "cid:" {
                let candidate = String(source.dropFirst(4))
                safeSource = allowed.contains(candidate) ? "cid:\(candidate)" : nil
            } else {
                safeSource = isHTTPSImageURL(source) ? source : nil
            }
            // Reescrever a tag evita preservar um `src` alternativo escondido
            // nos atributos. Mantemos a apresentação que cabe em uma imagem,
            // para uma assinatura importada não perder logo, dimensão ou
            // espaçamento silenciosamente.
            result.replaceSubrange(
                wholeRange,
                with: safeSource.map { safeImageTag(source: $0, originalTag: originalTag) } ?? ""
            )
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }
        return result
    }

    /// Uma versão que nunca lança para formulários que precisam manter o que
    /// a pessoa já escreveu enquanto apontam o problema visualmente.
    public static func sanitized(
        plainText: String, html: String? = nil,
        inlineResources: [InlineSignatureResource] = []
    ) -> EmailSignature {
        (try? EmailSignature(
            plainText: plainText, html: html, inlineResources: inlineResources
        )) ?? EmailSignature(legacyText: plainText)
    }

    private enum CodingKeys: String, CodingKey { case plainText, html, inlineResources }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let plainText = try values.decodeIfPresent(String.self, forKey: .plainText) ?? ""
        let html = try values.decodeIfPresent(String.self, forKey: .html)
        let resources = try values.decodeIfPresent([InlineSignatureResource].self, forKey: .inlineResources) ?? []
        try self.init(plainText: plainText, html: html, inlineResources: resources)
    }

    private static func sanitizePlainText(_ text: String) -> String {
        text.unicodeScalars.filter {
            $0.properties.generalCategory != .control || $0 == "\n" || $0 == "\t" || $0 == "\r"
        }.map(String.init).joined()
    }

    private static func plainTextFallback(from html: String?) -> String {
        guard var result = html else { return "" }
        let lineBreakMarker = "\u{E000}"
        result = replacing(result, pattern: #"<(br|/p|/div|/li|/tr|/h[1-6])\b[^>]*>"#,
                           options: [.caseInsensitive], with: lineBreakMarker)
        result = replacing(result, pattern: #"</(td|th)\b[^>]*>"#,
                           options: [.caseInsensitive], with: lineBreakMarker)
        result = replacing(result, pattern: #"<[^>]+>"#, options: [], with: "")
        result = result
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        let sanitized = sanitizePlainText(result)
        let lines = sanitized.components(separatedBy: lineBreakMarker).map { line in
            line.split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func safeImageTag(source: String, originalTag: String) -> String {
        var attributes = ""
        for name in ["alt", "title"] {
            if let raw = attribute(named: name, in: originalTag) {
                attributes += " \(name)=\"\(escapedAttribute(raw, maximumLength: 240))\""
            } else if name == "alt" {
                attributes += " alt=\"\""
            }
        }
        for name in ["width", "height"] {
            guard let raw = attribute(named: name, in: originalTag),
                  let value = safeDimension(raw)
            else { continue }
            attributes += " \(name)=\"\(value)\""
        }
        if let style = attribute(named: "style", in: originalTag),
           let safeStyle = sanitizedImageStyle(style) {
            attributes += " style=\"\(escapedAttribute(safeStyle, maximumLength: 2_048))\""
        }
        return "<img src=\"\(escapedURLAttribute(source))\"\(attributes)>"
    }

    private static func attribute(named name: String, in tag: String) -> String? {
        let pattern = #"(?:^|\s)"# + NSRegularExpression.escapedPattern(for: name)
            + #"\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(
                in: tag, range: NSRange(tag.startIndex..., in: tag)
              )
        else { return nil }
        for index in 1...3 {
            let range = match.range(at: index)
            if range.location != NSNotFound, let swiftRange = Range(range, in: tag) {
                return String(tag[swiftRange])
            }
        }
        return nil
    }

    private static func isHTTPSImageURL(_ source: String) -> Bool {
        guard source.utf8.count <= 4_096,
              source.unicodeScalars.allSatisfy({
                  $0.properties.generalCategory != .control && $0 != "\"" && $0 != "'" && $0 != "<" && $0 != ">"
              }),
              let components = URLComponents(string: source),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty
        else { return false }
        return true
    }

    private static func safeDimension(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 12 else { return nil }
        let normalized = value.lowercased()
        let unit: String
        let digits: Substring
        if normalized.hasSuffix("px") {
            unit = "px"
            digits = normalized.dropLast(2)
        } else if normalized.hasSuffix("%") {
            unit = "%"
            digits = normalized.dropLast()
        } else {
            unit = ""
            digits = Substring(normalized)
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
              let number = Int(digits), number > 0,
              number <= (unit == "%" ? 100 : 2_000)
        else { return nil }
        return "\(number)\(unit)"
    }

    private static func sanitizedImageStyle(_ raw: String) -> String? {
        let allowedProperties: Set<String> = [
            "display", "width", "height", "max-width", "max-height", "min-width", "min-height",
            "margin", "padding", "border", "border-radius", "vertical-align", "object-fit"
        ]
        let declarations = raw.split(separator: ";", omittingEmptySubsequences: true)
        let safeDeclarations = declarations.compactMap { declaration -> String? in
            let pieces = declaration.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return nil }
            let property = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let isAllowed = allowedProperties.contains(property)
                || property.hasPrefix("margin-")
                || property.hasPrefix("padding-")
                || property.hasPrefix("border-")
            guard isAllowed,
                  !value.isEmpty,
                  value.utf8.count <= 256,
                  isSafeStyleValue(value)
            else { return nil }
            return "\(property): \(value)"
        }
        guard !safeDeclarations.isEmpty else { return nil }
        return safeDeclarations.joined(separator: "; ")
    }

    private static func isSafeStyleValue(_ value: String) -> Bool {
        let lowered = value.lowercased()
        guard !lowered.contains("url("),
              !lowered.contains("expression"),
              !lowered.contains("@import"),
              !lowered.contains("javascript"),
              value.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control })
        else { return false }
        return true
    }

    private static func escapedAttribute(_ raw: String, maximumLength: Int) -> String {
        String(raw.prefix(maximumLength))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A URL chega do HTML colado e pode já ter `&amp;`. Reescapar aquela
    /// entidade mudaria a URL; só escapamos `&` que ainda está cru.
    private static func escapedURLAttribute(_ raw: String) -> String {
        let ampersand = try? NSRegularExpression(
            pattern: #"&(?!#(?:[0-9]+|x[0-9a-f]+);|[a-z][a-z0-9]+;)"#,
            options: [.caseInsensitive]
        )
        let escaped = ampersand?.stringByReplacingMatches(
            in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "&amp;"
        ) ?? raw
        return escaped
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func replacing(
        _ source: String, pattern: String,
        options: NSRegularExpression.Options, with template: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return source
        }
        return expression.stringByReplacingMatches(
            in: source, range: NSRange(source.startIndex..., in: source), withTemplate: template
        )
    }
}

/// Nome mais amplo para consumidores que tratam a imagem como parte da
/// mensagem inteira; a assinatura continua sendo o único produtor atual.
public typealias InlineEmailResource = InlineSignatureResource

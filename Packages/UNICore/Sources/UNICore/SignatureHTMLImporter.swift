import Foundation

/// Normaliza HTML que a pessoa colou em uma assinatura sem tentar redesenhá-lo.
///
/// O importador preserva tabelas, estilos inline e a ordem do markup. Seu único
/// trabalho é tornar as imagens portáveis: dados `data:image/...;base64` viram
/// recursos CID e URLs HTTPS são reportadas para a interface decidir se devem
/// ser incorporadas. A sanitização de HTML ativo continua sendo
/// responsabilidade de ``EmailSignature`` na hora de salvar/enviar.
public enum SignatureHTMLImporter {
    public struct ImportResult: Sendable, Hashable {
        /// Fragmento pronto para ser entregue ao editor ou ao sanitizador final.
        /// Documentos completos são reduzidos ao conteúdo de `<body>`.
        public let html: String
        /// Recursos que já existiam, mais os extraídos de `data:`.
        public let inlineResources: [InlineSignatureResource]
        /// Imagens HTTPS preservadas no HTML. O importador nunca baixa a rede.
        public let externalImageURLs: [String]
        /// Avisos apresentáveis pela UI; o conteúdo restante segue importável.
        public let warnings: [String]

        public init(
            html: String,
            inlineResources: [InlineSignatureResource],
            externalImageURLs: [String],
            warnings: [String]
        ) {
            self.html = html
            self.inlineResources = inlineResources
            self.externalImageURLs = externalImageURLs
            self.warnings = warnings
        }
    }

    /// Importa um fragmento ou documento HTML completo.
    ///
    /// Não lança: uma imagem inválida é retirada da saída e acrescenta um
    /// aviso, em vez de perder toda a assinatura que a pessoa colou.
    public static func normalize(
        source: String,
        existingResources: [InlineSignatureResource] = []
    ) -> ImportResult {
        var resources: [InlineSignatureResource] = []
        var knownContentIDs = Set<String>()
        var warnings: [String] = []

        for resource in existingResources {
            guard knownContentIDs.insert(resource.contentID).inserted else {
                warnings.append("Uma imagem incorporada repetida foi ignorada.")
                continue
            }
            resources.append(resource)
        }

        var externalURLs: [String] = []
        var knownExternalURLs = Set<String>()
        var fragment = bodyFragment(in: source)
        guard let imageExpression = try? NSRegularExpression(
            pattern: #"<img\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else {
            return ImportResult(
                html: fragment,
                inlineResources: resources,
                externalImageURLs: externalURLs,
                warnings: warnings
            )
        }

        let matches = imageExpression.matches(
            in: fragment,
            range: NSRange(fragment.startIndex..., in: fragment)
        )
        var inlineByteCount = resources.reduce(0) { $0 + $1.data.count }

        // A substituição ocorre de trás para frente porque cada data URI pode
        // diminuir bastante a string e invalidar os ranges seguintes.
        for match in matches.reversed() {
            guard let tagRange = Range(match.range, in: fragment) else { continue }
            let originalTag = String(fragment[tagRange])
            guard let sourceURL = imageSource(in: originalTag) else {
                continue
            }
            let normalizedURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)

            if normalizedURL.lowercased().hasPrefix("cid:") {
                let contentID = String(normalizedURL.dropFirst(4))
                if knownContentIDs.contains(contentID) {
                    continue
                }
                warnings.append("Uma imagem CID sem recurso correspondente foi removida.")
                fragment.removeSubrange(tagRange)
                continue
            }

            if isHTTPSURL(normalizedURL) {
                if knownExternalURLs.insert(normalizedURL).inserted {
                    externalURLs.append(normalizedURL)
                }
                continue
            }

            if normalizedURL.lowercased().hasPrefix("data:") {
                guard let decoded = decodeInlineImage(from: normalizedURL) else {
                    warnings.append("Uma imagem data: não suportada foi removida.")
                    fragment.removeSubrange(tagRange)
                    continue
                }

                if let existing = resources.first(where: {
                    $0.mimeType == decoded.mimeType && $0.data == decoded.data
                }) {
                    fragment.replaceSubrange(
                        tagRange,
                        with: replacingImageSource(in: originalTag, with: existing.cidURL)
                    )
                    continue
                }

                guard decoded.data.count <= InlineSignatureResource.maximumByteCount else {
                    warnings.append("Uma imagem incorporada excede o limite de 2 MB e foi removida.")
                    fragment.removeSubrange(tagRange)
                    continue
                }
                guard resources.count < EmailSignature.maximumInlineResourceCount else {
                    warnings.append("A assinatura aceita no máximo 8 imagens incorporadas; uma imagem foi removida.")
                    fragment.removeSubrange(tagRange)
                    continue
                }
                guard inlineByteCount + decoded.data.count <= EmailSignature.maximumInlineResourceByteCount else {
                    warnings.append("As imagens incorporadas excedem o limite total de 5 MB; uma imagem foi removida.")
                    fragment.removeSubrange(tagRange)
                    continue
                }

                do {
                    var contentID = InlineSignatureResource.newContentID()
                    while knownContentIDs.contains(contentID) {
                        contentID = InlineSignatureResource.newContentID()
                    }
                    let resource = try InlineSignatureResource(
                        contentID: contentID,
                        mimeType: decoded.mimeType,
                        data: decoded.data
                    )
                    resources.append(resource)
                    knownContentIDs.insert(resource.contentID)
                    inlineByteCount += resource.data.count
                    fragment.replaceSubrange(
                        tagRange,
                        with: replacingImageSource(in: originalTag, with: resource.cidURL)
                    )
                } catch {
                    warnings.append("Uma imagem incorporada inválida foi removida.")
                    fragment.removeSubrange(tagRange)
                }
                continue
            }

            warnings.append("Uma imagem local, HTTP ou ativa foi removida. Use HTTPS ou incorpore a imagem.")
            fragment.removeSubrange(tagRange)
        }

        return ImportResult(
            html: fragment.trimmingCharacters(in: .whitespacesAndNewlines),
            inlineResources: resources,
            externalImageURLs: externalURLs,
            warnings: warnings
        )
    }

    private static func bodyFragment(in source: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"<body\b[^>]*>(.*?)</body\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ), let match = expression.firstMatch(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        ), let contentRange = Range(match.range(at: 1), in: source) else {
            return source.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(source[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func imageSource(in tag: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"\bsrc\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#,
            options: [.caseInsensitive]
        ), let match = expression.firstMatch(
            in: tag,
            range: NSRange(tag.startIndex..., in: tag)
        ) else { return nil }

        for capture in 1...3 {
            let range = match.range(at: capture)
            if range.location != NSNotFound, let swiftRange = Range(range, in: tag) {
                return String(tag[swiftRange])
            }
        }
        return nil
    }

    private static func replacingImageSource(in tag: String, with source: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"\bsrc\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)"#,
            options: [.caseInsensitive]
        ), let match = expression.firstMatch(
            in: tag,
            range: NSRange(tag.startIndex..., in: tag)
        ), let range = Range(match.range, in: tag) else {
            return tag
        }
        var result = tag
        result.replaceSubrange(range, with: "src=\"\(source)\"")
        return result
    }

    private static func isHTTPSURL(_ source: String) -> Bool {
        guard let url = URL(string: source) else { return false }
        return url.scheme?.lowercased() == "https" && url.host != nil
    }

    private static func decodeInlineImage(from source: String) -> (mimeType: String, data: Data)? {
        guard let expression = try? NSRegularExpression(
            pattern: #"^data:(image/(?:png|jpeg|gif|webp));base64,([A-Za-z0-9+/=\s]+)$"#,
            options: [.caseInsensitive]
        ), let match = expression.firstMatch(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        ), let mimeRange = Range(match.range(at: 1), in: source),
           let dataRange = Range(match.range(at: 2), in: source) else { return nil }

        let encoded = String(source[dataRange]).components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else { return nil }
        return (String(source[mimeRange]).lowercased(), data)
    }
}

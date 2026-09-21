import Foundation

/// Prepara imagens inline de um HTML já salvo exclusivamente na fronteira de
/// envio. Rascunhos continuam guardando seus `data:` originais para que uma
/// reabertura não deixe CIDs sem os bytes que lhes pertencem.
public enum OutgoingHTMLResources {
    public struct Result: Sendable, Hashable {
        public let html: String?
        public let inlineResources: [InlineSignatureResource]
        public let warnings: [String]

        public init(
            html: String?, inlineResources: [InlineSignatureResource], warnings: [String]
        ) {
            self.html = html
            self.inlineResources = inlineResources
            self.warnings = warnings
        }
    }

    /// Converte somente imagens `data:image/...` em recursos CID válidos. A
    /// normalização existente trabalha com o conteúdo de `<body>`; aqui ele é
    /// recolocado no documento original para conservar atributos de `<body>`,
    /// `<head>` e a estrutura que a pessoa vai revisar no compositor.
    public static func materialize(
        html: String?, existingResources: [InlineSignatureResource] = []
    ) -> Result {
        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Result(html: html, inlineResources: existingResources, warnings: [])
        }

        let imported = SignatureHTMLImporter.normalize(
            source: html, existingResources: existingResources
        )
        return Result(
            html: replacingBody(in: html, with: imported.html),
            inlineResources: imported.inlineResources,
            warnings: imported.warnings
        )
    }

    private static func replacingBody(in document: String, with fragment: String) -> String {
        guard let bodyOpen = document.range(of: "<body", options: .caseInsensitive),
              let openEnd = document.range(of: ">", range: bodyOpen.lowerBound..<document.endIndex),
              let bodyClose = document.range(
                of: "</body>", options: [.caseInsensitive, .backwards]
              ), openEnd.upperBound <= bodyClose.lowerBound
        else { return fragment }

        var result = document
        result.replaceSubrange(openEnd.upperBound..<bodyClose.lowerBound, with: fragment)
        return result
    }
}

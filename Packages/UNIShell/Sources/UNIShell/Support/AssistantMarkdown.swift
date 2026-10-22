import SwiftUI
import UNIDesign

/// Blocos simples de Markdown voltados ao que o assistente produz no leitor.
/// SwiftUI achata listas quando um documento inteiro é entregue a um único
/// Text; separar os blocos conserva bullets, numeração e respiro entre ideias.
struct AssistantMarkdownBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case paragraph(String)
        case heading(String)
        case bullet(String)
        case numbered(marker: String, text: String)
    }

    let id: Int
    let kind: Kind

    nonisolated static func parse(_ text: String) -> [Self] {
        var kinds: [Kind] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            kinds.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                flushParagraph()
                continue
            }

            if let heading = headingText(in: line) {
                flushParagraph()
                kinds.append(.heading(stripWrappingEmphasis(heading)))
            } else if let heading = emphasisHeading(in: line) {
                // O modelo escreve o título da seção como uma linha inteira
                // entre `**`. Sem isto a linha caía no parágrafo e os
                // asteriscos iam para a tela.
                flushParagraph()
                kinds.append(.heading(heading))
            } else if let item = unorderedItem(in: line) {
                flushParagraph()
                kinds.append(.bullet(item))
            } else if let item = orderedItem(in: line) {
                flushParagraph()
                kinds.append(.numbered(marker: item.marker, text: item.text))
            } else {
                paragraphLines.append(line)
            }
        }
        flushParagraph()

        return kinds.enumerated().map { index, kind in
            Self(id: index, kind: kind)
        }
    }

    /// A primeira frase, sem marcador, para a linha recolhida do cartão.
    nonisolated static func plainPreview(_ text: String) -> String {
        let raw: String
        if let first = parse(text).first {
            switch first.kind {
            case .paragraph(let value), .heading(let value), .bullet(let value):
                raw = value
            case .numbered(_, let value):
                raw = value
            }
        } else {
            raw = text
        }
        return stripInlineMarkers(raw)
    }

    /// Tira `**`, `__` e o itálico de uma linha que vai ser desenhada crua.
    nonisolated static func stripInlineMarkers(_ text: String) -> String {
        var stripped = text
        for token in ["***", "**", "__", "`"] {
            stripped = stripped.replacingOccurrences(of: token, with: "")
        }
        stripped = stripped.replacingOccurrences(of: "*", with: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func headingText(in line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 3 else { return nil }
        let remainder = line.dropFirst(hashes.count)
        guard remainder.first == " " else { return nil }
        let text = remainder.dropFirst().trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Uma linha que é só um negrito (`**título**` ou `__título__`) é título.
    /// `**Em resumo:** o resto da frase` não entra: o negrito é só o começo.
    private nonisolated static func emphasisHeading(in line: String) -> String? {
        for marker in ["***", "**", "__"] {
            guard line.hasPrefix(marker), line.hasSuffix(marker) else { continue }
            guard line.count > marker.count * 2 else { continue }
            let inner = line.dropFirst(marker.count).dropLast(marker.count)
            guard !inner.contains(marker) else { continue }
            let text = inner.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            return text
        }
        return nil
    }

    private nonisolated static func stripWrappingEmphasis(_ text: String) -> String {
        emphasisHeading(in: text) ?? text
    }

    private nonisolated static func unorderedItem(in line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            let item = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return item.isEmpty ? nil : item
        }
        return nil
    }

    private nonisolated static func orderedItem(in line: String) -> (marker: String, text: String)? {
        guard let separator = line.firstIndex(of: " ") else { return nil }
        let marker = String(line[..<separator])
        guard marker.count >= 2,
              marker.last == "." || marker.last == ")",
              Int(marker.dropLast()) != nil
        else {
            return nil
        }
        let item = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : (marker, item)
    }
}

/// Renderiza a resposta do assistente como Markdown leve (títulos, bullets,
/// numeração e parágrafos).
///
/// Turno `kind: .draft` é prosa de email: asterisco e hífen ali são
/// literais que a pessoa vai colar no composer — não passe texto de rascunho
/// para este view.
struct AssistantMarkdown: View {
    /// Como o corpo é desenhado.
    ///
    /// `.compact` é o que o painel e o popover do leitor sempre desenharam:
    /// sans 12.5 em `ink2`. `.prose(size:)` é o que a faixa de briefing e o
    /// transcript do dashboard pedem no mockup — o serif do tema no corpo
    /// dado, em `ink`, com o `line-height: 1.55` que o CSS escreve.
    /// `.card(size:)` é o cartão do leitor: sans naquele corpo, peso 500,
    /// `line-height: 1.45`, e o título de seção em negrito.
    enum Style: Equatable {
        case compact
        case prose(size: CGFloat)
        case card(size: CGFloat)

        /// `line-height` menos a altura natural de linha (≈1.2): é isso
        /// que o `lineSpacing` do SwiftUI acrescenta.
        var lineSpacing: CGFloat {
            switch self {
            case .compact: 2.5
            case .prose(let size): size * 0.35
            case .card(let size): size * 0.25
            }
        }
    }

    @Environment(\.theme) private var theme

    let text: String
    var style: Style = .compact

    var body: some View {
        VStack(alignment: .leading, spacing: blockSpacing) {
            ForEach(AssistantMarkdownBlock.parse(text)) { block in
                blockView(block.kind)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ kind: AssistantMarkdownBlock.Kind) -> some View {
        switch kind {
        case .paragraph(let text):
            styled(text, weight: bodyWeight)
        case .heading(let text):
            styled(text, weight: headingWeight)
                .padding(.top, headingTop)
        case .bullet(let text):
            let rise = markerRise
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(markerInk.color)
                    .frame(width: 4, height: 4)
                    // **O ponto no meio da primeira linha, e não na linha de
                    // base dela.** Dizer que a base do ponto é o centro dele
                    // punha o ponto *sobre* a base — visivelmente abaixo do
                    // olho da letra, que foi o que o dono viu na lista da
                    // mesa. Descer a base dentro do ponto o levanta até a
                    // altura-x, que é onde o olho espera o marcador.
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[VerticalAlignment.center] + rise
                    }
                styled(text, weight: bodyWeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .numbered(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker)
                    .font(theme.mono.font(size: 10.5, weight: .medium))
                    .foregroundStyle(markerInk.color)
                    .frame(minWidth: 18, alignment: .trailing)
                styled(text, weight: bodyWeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func styled(_ value: String, weight: Font.Weight) -> some View {
        Text(inline(value, weight: weight))
            .foregroundStyle(bodyInk.color)
            .lineSpacing(style.lineSpacing)
            .tracking(tracking)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Quanto o marcador sobe da linha de base: metade da altura-x, que para
    /// as fontes do app fica perto de um quarto do corpo.
    private var markerRise: CGFloat {
        switch style {
        case .compact: 12.5 * 0.25
        case .prose(let size), .card(let size): size * 0.25
        }
    }

    private var blockSpacing: CGFloat {
        switch style {
        case .compact, .prose: 7
        case .card: 6
        }
    }

    /// O título respira em relação ao parágrafo de cima e cola na lista
    /// de baixo. No painel a folga continua curta, como sempre foi.
    private var headingTop: CGFloat {
        switch style {
        case .compact, .prose: 2
        case .card: 10
        }
    }

    private var bodyWeight: Font.Weight {
        switch style {
        case .compact, .prose: .regular
        case .card: .medium
        }
    }

    private var headingWeight: Font.Weight {
        switch style {
        case .compact, .prose: .semibold
        case .card: .bold
        }
    }

    private var tracking: CGFloat {
        switch style {
        case .compact, .prose: 0
        case .card(let size): size * -0.005
        }
    }

    private var bodySize: CGFloat {
        switch style {
        case .compact: 12.5
        case .prose(let size), .card(let size): size
        }
    }

    private func face(weight: Font.Weight) -> Font {
        switch style {
        case .compact, .card:
            theme.sans.font(size: bodySize, weight: weight)
        case .prose:
            theme.serif.font(size: bodySize, weight: weight)
        }
    }

    private var bodyInk: TokenColor {
        switch style {
        case .compact: theme.ink2
        case .prose, .card: theme.ink
        }
    }

    /// No cartão o ponto segue o fio de acento. No painel continua `info`,
    /// que é a cor que a lista de lá sempre usou.
    private var markerInk: TokenColor {
        switch style {
        case .compact, .prose: theme.info
        case .card: theme.accentInk
        }
    }

    /// O negrito e o itálico vão na fonte de cada trecho. Um `.font` no
    /// `Text` inteiro achatava o que o Markdown tinha marcado, e era assim
    /// que `**título**` ou sumia ou voltava com asterisco.
    private func inline(_ value: String, weight: Font.Weight) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard var parsed = try? AttributedString(markdown: value, options: options) else {
            var plain = AttributedString(value)
            plain.font = face(weight: weight)
            return plain
        }
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            let strong = intent.contains(.stronglyEmphasized)
            let italic = intent.contains(.emphasized)
            var font = face(weight: strong ? emphasizedWeight(over: weight) : weight)
            if italic { font = font.italic() }
            if intent.contains(.code) {
                font = theme.mono.font(size: bodySize * 0.92, weight: .medium)
            }
            parsed[run.range].font = font
        }
        return parsed
    }

    private func emphasizedWeight(over base: Font.Weight) -> Font.Weight {
        if base == .medium || base == .semibold || base == .bold { return .bold }
        return .semibold
    }
}

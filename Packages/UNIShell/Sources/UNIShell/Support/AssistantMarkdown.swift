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

    private nonisolated static func headingText(in line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 3 else { return nil }
        let remainder = line.dropFirst(hashes.count)
        guard remainder.first == " " else { return nil }
        let text = remainder.dropFirst().trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
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
    @Environment(\.theme) private var theme

    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
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
            richText(text)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink2.color)
                .lineSpacing(2.5)
        case .heading(let text):
            richText(text)
                .font(theme.sans.font(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .padding(.top, 2)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(theme.info.color)
                    .frame(width: 4, height: 4)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[VerticalAlignment.center]
                    }
                richText(text)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink2.color)
                    .lineSpacing(2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .numbered(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker)
                    .font(theme.mono.font(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.info.color)
                    .frame(minWidth: 18, alignment: .trailing)
                richText(text)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink2.color)
                    .lineSpacing(2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func richText(_ value: String) -> Text {
        Text((try? AttributedString(markdown: value)) ?? AttributedString(value))
    }
}

import SwiftUI
import UNICore
import UNIDesign

/// A ponte entre a seleção do `TextEditor` e o modelo puro de `UNICore`.
///
/// Um `enum` sem `View` em volta — `View` é `@MainActor` implícito no Swift 6 e
/// lógica pura dentro dela trapa em teste nonisolated.
///
/// É aqui que o defeito da Task W morre: a barra antiga aplicava `.font(...)` ao
/// `TextEditor` inteiro porque o corpo era uma `String`. Agora o corpo é
/// `AttributedString`, o editor devolve `AttributedTextSelection`, e todo
/// comando age sobre **os intervalos selecionados** — ou, sem seleção, sobre os
/// atributos de digitação, que é o que o próximo caractere vai herdar.
enum ComposerEditor {

    // MARK: - Leitura

    /// Os intervalos que a seleção cobre. Um ponto de inserção vira um
    /// intervalo vazio, que é o que `RichBody` espera para dizer "sem seleção".
    static func ranges(
        _ selection: AttributedTextSelection,
        in text: AttributedString
    ) -> [Range<AttributedString.Index>] {
        switch selection.indices(in: text) {
        case .insertionPoint(let index):
            return [index..<index]
        case .ranges(let set):
            return Array(set.ranges)
        }
    }

    /// O que a barra mostra. Com o cursor solto, vale o estilo dos atributos de
    /// digitação — senão apertar B, mover o cursor e voltar mostraria mentira.
    static func reading(
        of text: AttributedString,
        selection: AttributedTextSelection
    ) -> BodyReading {
        RichBody.reading(
            of: text,
            over: ranges(selection, in: text),
            typing: selection.typingAttributes(in: text)[BodyStyleAttribute.self]
        )
    }

    // MARK: - Escrita

    /// **Toda** escrita passa por `transform(updating:)`, inclusive a que só
    /// mexe em atributos.
    ///
    /// Isso não é zelo: medido nesta máquina, escrever um atributo num trecho
    /// parte os runs e faz `AttributedTextSelection.indices(in:)` degradar para
    /// um ponto de inserção. Sem o `updating:`, negritar e em seguida
    /// italizar a mesma seleção aplicava o itálico **aos atributos de
    /// digitação** — a seleção do usuário sumia entre um clique e o outro.
    static func perform(
        _ command: ComposerCommand,
        on text: inout AttributedString,
        selection: inout AttributedTextSelection,
        theme: Theme
    ) {
        let spans = ranges(selection, in: text)
        let state = reading(of: text, selection: selection)
        let hasSelection = spans.contains { !$0.isEmpty }

        // Sem seleção, um comando de estilo vale para o que vier em seguida —
        // é o que qualquer editor faz. `transformAttributes` num ponto de
        // inserção reescreve exatamente os atributos de digitação.
        if !hasSelection, let restyling = Self.restyling(command, state: state) {
            text.transformAttributes(in: &selection) { container in
                var style = container[BodyStyleAttribute.self] ?? .default
                restyling(&style)
                ComposerFormatting.project(style, into: &container, theme: theme)
            }
            return
        }

        text.transform(updating: &selection) { text in
            if let restyling = Self.restyling(command, state: state) {
                RichBody.restyle(&text, over: spans, restyling)
            } else {
                switch command {
                case .align(let alignment):
                    RichBody.align(&text, over: spans, to: alignment)
                case .list(let kind):
                    RichBody.setList(&text, over: spans, to: kind)
                case .indent(let delta):
                    RichBody.indent(&text, over: spans, by: delta)
                default:
                    break
                }
            }
            if case .clearFormatting = command {
                RichBody.align(&text, over: spans, to: .left)
            }
            decorate(&text, theme: theme)
        }
    }

    /// A transformação de estilo que o comando pede, ou nulo se ele for de
    /// parágrafo. O alvo dos alternadores sai do estado **lido antes**: um
    /// processador de texto liga o negrito para toda a seleção quando ela ainda
    /// não está inteira em negrito.
    private static func restyling(
        _ command: ComposerCommand,
        state: BodyReading
    ) -> ((inout BodyStyle) -> Void)? {
        switch command {
        case .family(let name): return { $0.family = name }
        case .size(let size): return { $0.size = size }
        case .bold: let on = !state.bold; return { $0.bold = on }
        case .italic: let on = !state.italic; return { $0.italic = on }
        case .underline: let on = !state.underline; return { $0.underline = on }
        case .strike: let on = !state.strike; return { $0.strike = on }
        case .color(let hex): return { $0.colorHex = hex }
        case .highlight(let hex): return { $0.highlightHex = hex }
        case .clearFormatting: return { $0 = .default }
        case .align, .list, .indent: return nil
        }
    }

    /// Reescreve os atributos que o SwiftUI desenha a partir do `BodyStyle` de
    /// cada trecho. Colhe as faixas antes de escrever: escrever atributo não
    /// move índice, então elas continuam válidas.
    static func decorate(_ text: inout AttributedString, theme: Theme) {
        let spans = text.runs.map { ($0.range, RichBody.style(of: $0.attributes)) }
        for (range, style) in spans {
            var container = AttributeContainer()
            ComposerFormatting.project(style, into: &container, theme: theme)
            text[range].mergeAttributes(container, mergePolicy: .keepNew)
            // `mergeAttributes` não apaga; o realce ausente e o sublinhado
            // desligado precisam sumir de verdade.
            if ComposerFormatting.highlight(style.highlightHex) == nil {
                text[range].backgroundColor = nil
            }
            if !style.underline { text[range].underlineStyle = nil }
            if !style.strike { text[range].strikethroughStyle = nil }
        }
    }
}

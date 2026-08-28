import SwiftUI
import UNICore
import UNIDesign

/// A folha que pede a URL — o que faltava para o `↗` sair do desabilitado.
///
/// **Painel nosso, não folha do sistema.** O motivo é o mesmo que tirou o
/// `Picker(.menu)` da barra: um `NSAlert` ou um `.sheet` do SwiftUI pinta a
/// moldura do macOS por cima do desenho do protótipo, e o dono do projeto já
/// relatou isso uma vez. O desenho copiado é o do seletor de tema (linha 328 do
/// `.dc.html`), que é o único menu próprio do protótipo — mesma superfície,
/// mesma borda, mesma sombra.
///
/// Com trecho selecionado o painel só pede a URL: o texto do link já é o que
/// está selecionado. Sem seleção ele pede as duas coisas, porque um link
/// precisa de algo escrito para pendurar.
struct ComposerLinkPanel: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let current: URL?
    let hasSelection: Bool
    let canRemove: Bool
    let apply: (URL?, String) -> Void
    let cancel: () -> Void

    @State private var address: String
    @State private var label: String

    init(
        current: URL?,
        hasSelection: Bool,
        canRemove: Bool,
        apply: @escaping (URL?, String) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.current = current
        self.hasSelection = hasSelection
        self.canRemove = canRemove
        self.apply = apply
        self.cancel = cancel
        _address = State(initialValue: current?.absoluteString ?? "")
        _label = State(initialValue: "")
    }

    /// O que de fato vira link. Uma pessoa digita `okamiuni.com.br` e espera um
    /// link; sem esquema, `URL` monta um caminho relativo que não abre nada.
    static func url(from typed: String) -> URL? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") || trimmed.hasPrefix("mailto:") {
            return URL(string: trimmed)
        }
        if trimmed.contains("@"), !trimmed.contains("/") {
            return URL(string: "mailto:\(trimmed)")
        }
        return URL(string: "https://\(trimmed)")
    }

    private var resolved: URL? { Self.url(from: address) }

    /// O texto que entra junto quando não há seleção: o que a pessoa escreveu,
    /// ou o próprio endereço.
    private var resolvedLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? address.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            field(title: "Endereço", text: $address, placeholder: "okamiuni.com.br")
            if !hasSelection {
                field(title: "Texto", text: $label, placeholder: "o que aparece no email")
            }

            HStack(spacing: 7) {
                if canRemove {
                    ChromeButton(
                        appearance: .outlined, height: 24, horizontalPadding: 10,
                        labelSize: 11.5, labelWeight: .medium,
                        action: { apply(nil, "") }
                    ) {
                        Text("Remover")
                    }
                }
                Spacer(minLength: 0)
                ChromeButton(
                    appearance: .outlined, height: 24, horizontalPadding: 10,
                    labelSize: 11.5, labelWeight: .medium,
                    action: cancel
                ) {
                    Text("Cancelar")
                }
                ChromeButton(
                    appearance: .accent, height: 24, horizontalPadding: 10,
                    labelSize: 11.5, labelWeight: .medium,
                    action: { if let resolved { apply(resolved, resolvedLabel) } }
                ) {
                    Text("Aplicar")
                }
                .disabled(resolved == nil)
                .opacity(resolved == nil ? 0.5 : 1)
            }
        }
        .padding(10)
        .frame(width: 268)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 10)
        .fixedSize()
    }

    private func field(title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).capsLabel()
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink.color)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(theme.btn.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(
                            theme.btnLine.color, lineWidth: Hairline.thickness(displayScale)
                        )
                }
        }
    }
}

/// A grade que escolhe o tamanho da tabela.
///
/// É o gesto que Word, Pages e Gmail usam: passar o ponteiro pela grade e
/// clicar. Um par de campos numéricos faria a mesma coisa em três gestos, e a
/// grade já **é** a pré-visualização do que vai ser inserido.
struct ComposerTablePanel: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    /// O teto do gesto. Além disto a grade fica maior que a janela, e tabela
    /// grande se faz crescendo a pequena.
    static let maximum = 6

    let pick: (Int, Int) -> Void

    /// Só para verificação fora da tela: sem ponteiro não há `hover`, e sem
    /// `hover` não haveria como provar que a grade acende.
    var debugHover: (rows: Int, columns: Int)?

    @State private var hovered: (rows: Int, columns: Int)?

    init(debugHover: (rows: Int, columns: Int)? = nil, pick: @escaping (Int, Int) -> Void) {
        self.pick = pick
        self.debugHover = debugHover
        _hovered = State(initialValue: debugHover)
    }

    /// Protótipo `tblStyle`: célula de 18pt com a hairline do tema.
    private static let cell: CGFloat = 18
    private static let gap: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(theme.mono.font(size: 9.5, weight: .medium))
                .foregroundStyle(theme.ink3.color)

            VStack(spacing: Self.gap) {
                ForEach(1...Self.maximum, id: \.self) { row in
                    HStack(spacing: Self.gap) {
                        ForEach(1...Self.maximum, id: \.self) { column in
                            cellButton(row: row, column: column)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 10)
        .fixedSize()
    }

    private var caption: String {
        guard let hovered else { return "TABELA" }
        return "\(hovered.rows) × \(hovered.columns)"
    }

    private func cellButton(row: Int, column: Int) -> some View {
        let lit = (hovered?.rows ?? 0) >= row && (hovered?.columns ?? 0) >= column
        return Button { pick(row, column) } label: {
            RoundedRectangle(cornerRadius: 2)
                .fill(lit ? theme.accentSoft.color : theme.btn.color)
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(
                            lit ? theme.accent.color : theme.btnLine.color,
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
                .frame(width: Self.cell, height: Self.cell)
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 2)
        .onHover { inside in
            if inside { hovered = (row, column) } else if hovered?.rows == row,
                hovered?.columns == column { hovered = debugHover }
        }
        .help("Tabela de \(row) por \(column)")
    }
}

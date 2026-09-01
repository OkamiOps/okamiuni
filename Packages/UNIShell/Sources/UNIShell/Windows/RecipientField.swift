import SwiftUI
import UNIDesign
import UNICore

/// Um campo de destinatários — Para, Cc, Cco, ou o "Encaminhar convite" da
/// tela 04. Etiquetas que quebram linha, um campo de digitação que ocupa o
/// resto e o menu de sugestões flutuando por baixo.
///
/// Protótipo: `toField(key)`, mais o CSS das linhas 400–413 (Para), 434–447
/// (Cc) e 448–461 (Cco). O menu é o mesmo cartão nas três.
struct RecipientField: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    /// Rótulo em versalete à esquerda. `nil` esconde a calha inteira — é o
    /// caso do campo de encaminhar, que não tem rótulo lateral.
    var label: String?
    /// Protótipo: `width: 52px` na calha do rótulo.
    var labelWidth: CGFloat = 52
    let placeholder: String
    /// Protótipo: `min-width: 160px` no Para, `140px` no Cc/Cco.
    var inputMinWidth: CGFloat = 140
    /// Protótipo: 340pt no Para, 330 no Cc/Cco, 320 no encaminhar.
    var menuWidth: CGFloat = 340
    let pool: [DirectoryContact]
    @Binding var chips: [Contact]
    /// Texto ainda não fechado em etiqueta. O pai lê isto ao enviar/adicionar
    /// para não perder o email que estava no campo.
    var typed: Binding<String>? = nil
    /// Porta do harness: o menu só abre com foco, e a renderização fora da tela
    /// nunca entrega foco a ninguém. Semear a busca abre o menu sem clique — é
    /// a mesma porta que `BandRecipientRow` já tem na faixa do leitor. Nula no
    /// app.
    var seededQuery: String?
    /// `true` (composer): o menu flutua por cima da linha de baixo. `false`
    /// (formulário com scroll): entra no fluxo, senão Local/Notas e o rodapé
    /// roubam o clique.
    var floatsMenu: Bool = true

    @State private var query = ""
    @State private var seeded = false
    @State private var fieldHeight: CGFloat = 24
    @State private var hoveringMenu = false
    @FocusState private var focused: Bool

    private var queryBinding: Binding<String> {
        Binding(
            get: { typed?.wrappedValue ?? query },
            set: { new in
                query = new
                typed?.wrappedValue = new
            }
        )
    }

    private var liveQuery: String { queryBinding.wrappedValue }

    private var suggestions: [DirectoryContact] {
        ContactDirectory.suggestions(matching: liveQuery, excluding: chips, in: pool)
    }

    private var menuOpen: Bool {
        !suggestions.isEmpty && (focused || hoveringMenu || seededQuery != nil)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let label {
                Text(label)
                    .capsLabel()
                    // Protótipo: `padding-top: 6px` na calha do "Para", para o
                    // rótulo alinhar com a primeira linha de etiquetas.
                    .padding(.top, 6)
                    .frame(width: labelWidth, alignment: .leading)
            }
            field
        }
        .task {
            guard !seeded else { return }
            if let seededQuery { query = seededQuery }
            seeded = true
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            inputRow
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldHeight = $0 }
            if menuOpen && !floatsMenu {
                menu
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if menuOpen && floatsMenu {
                menu
                    // Protótipo: o cartão nasce `top: 30px` abaixo do campo de
                    // 24pt — 6pt de folga, a mesma nos três campos.
                    .offset(y: fieldHeight + 6)
                    .zIndex(40)
            }
        }
    }

    private var inputRow: some View {
        FlowLayout(spacing: 5, rowSpacing: 5, stretchesLast: true) {
            ForEach(chips) { chip in
                self.chip(chip)
            }
            TextField(placeholder, text: queryBinding)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 13))
                .foregroundStyle(theme.ink.color)
                .frame(minWidth: inputMinWidth, maxWidth: .infinity)
                .frame(height: 24)
                .focused($focused)
                .onSubmit { commitFirst() }
                .onChange(of: query) { _, new in resolveSeparator(new) }
                .onKeyPress(.delete) {
                    guard query.isEmpty, !chips.isEmpty else { return .ignored }
                    chips.removeLast()
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard focused || hoveringMenu else { return .ignored }
                    focused = false
                    hoveringMenu = false
                    return .handled
                }
        }
    }

    private func chip(_ contact: Contact) -> some View {
        HStack(spacing: 7) {
            Text(contact.name.isEmpty ? contact.address : contact.name)
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.accentInk.color)
                .lineLimit(1)
            Button {
                chips.removeAll { $0.id == contact.id }
            } label: {
                Text("×")
                    .font(theme.sans.font(size: 11))
                    .foregroundStyle(theme.accentInk.color)
                    .frame(width: 15, height: 15)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusRing(in: Circle())
        }
        .frame(height: 24)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        // Raio 12 literal no protótipo (`border-radius: 12px`), não `var(--r2)`:
        // a etiqueta é uma cápsula em qualquer tema.
        .background(theme.accentSoft.color)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.accentLine.color, lineWidth: Hairline.thickness(displayScale))
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ContactDirectory.menuLabel(query: query))
                .capsLabel()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 7)
                .padding(.bottom, 5)
                .hairline(theme.line2, edges: .bottom)

            ForEach(suggestions) { suggestion in
                SuggestionRow(suggestion: suggestion) { add(suggestion) }
                    .hairline(theme.line2, edges: .bottom)
            }
        }
        .frame(width: menuWidth)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        // `0 18px 40px rgba(0,0,0,0.24)` — o blur do CSS vale o dobro do raio.
        .shadow(color: .black.opacity(0.24), radius: 20, x: 0, y: 18)
        .onHover { hoveringMenu = $0 }
    }

    private func add(_ suggestion: DirectoryContact) {
        guard !chips.contains(where: { $0.id == suggestion.contact.id }) else { return }
        chips.append(suggestion.contact)
        queryBinding.wrappedValue = ""
    }

    private func commitFirst() {
        guard let first = suggestions.first else { return }
        add(first)
    }

    /// Protótipo: terminar com ";" ou "," fecha a etiqueta ali mesmo.
    private func resolveSeparator(_ text: String) {
        guard text.hasSuffix(";") || text.hasSuffix(",") else { return }
        let raw = String(text.dropLast())
        guard let resolved = ContactDirectory.resolve(typed: raw, in: pool) else {
            queryBinding.wrappedValue = ""
            return
        }
        add(resolved)
    }
}

/// Uma linha do menu: avatar, nome, email e a organização à direita.
private struct SuggestionRow: View {
    @Environment(\.theme) private var theme
    @State private var hovering = false
    let suggestion: DirectoryContact
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(suggestion.initials)
                    .font(theme.sans.font(size: 9.5, weight: .bold))  // CSS 650
                    .foregroundStyle(theme.ink2.color)
                    .frame(width: 24, height: 24)
                    .background(theme.surface3.color)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 0) {
                    Text(suggestion.name)
                        .font(theme.sans.font(size: 12.5, weight: .semibold))  // 590
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                    Text(suggestion.address)
                        .font(theme.sans.font(size: 11))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(suggestion.org)
                    .font(theme.mono.font(size: 9, weight: .medium))
                    // 0.08em literal no protótipo, não `var(--caps)`.
                    .tracking(0.08 * 9)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.ink4.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? theme.accentSoft.color : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(in: Rectangle())
        .onHover { hovering = $0 }
        // O clique não pode depender só do Button: o TextField perde o foco
        // primeiro, o menu some e o clique cai no campo de baixo.
        .simultaneousGesture(TapGesture().onEnded(action))
    }
}

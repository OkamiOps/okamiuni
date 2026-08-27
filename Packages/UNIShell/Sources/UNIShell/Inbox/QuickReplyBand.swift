import SwiftUI
import UNIDesign
import UNICore

/// A faixa de resposta rápida embutida no leitor — protótipo, tela **01 Caixa
/// unificada**, a partir da linha 1128.
///
/// É o "mini composer" do leitor: campo "Para" com etiquetas e menu de
/// sugestões, área de escrita, e as duas saídas — "Responder aqui", que resolve
/// a resposta sem sair da tela, e "⤢", que promove o que já foi escrito para a
/// janela cheia.
///
/// **O que ela não tem, e por quê.** O protótipo põe também Cc/Cco, barra de
/// formatação, anexos e seletor de rascunho sugerido dentro desta mesma faixa.
/// Nada disso está aqui: a faixa é o caminho curto, e quem precisa dos dois
/// primeiros tem o "⤢" a um clique. A janela 03 já traz todos eles.
///
/// **Sobre o botão "Responder aqui".** O protótipo desenha, nesta faixa, uma
/// fila "Enviar · Enviar e arquivar · Salvar" (linha 1319), e o botão
/// "Responder aqui" com esta aparência vive na tela 02 (linha 777). O Marco 1
/// não tem rede: um botão escrito "Enviar" mentiria. "Responder aqui" é o que
/// a faixa de fato faz — guarda a resposta e fecha — com a forma do botão da
/// linha 777. A divergência está registrada no relatório da tarefa.
struct QuickReplyBand: View {
    @Environment(\.theme) private var theme

    let store: MailStore
    let message: Message
    /// O "⤢": promove esta resposta para a janela cheia. Quem recebe já
    /// encontra o rascunho em `store.replyDraft(for:)`.
    let onPromote: (Message) -> Void

    /// Porta do harness de renderização. Ele desenha fora da tela e nunca
    /// entrega foco a ninguém, então sem isto não há como verificar a aparência
    /// do menu de sugestões. Não muda nada no app: o padrão é `nil`.
    var seededQuery: String?

    @State private var open = true
    @State private var to: [Contact] = []
    @State private var text = ""
    @State private var query = ""
    @State private var savedAt: Date?
    @State private var seeded = false
    @State private var fieldHeight: CGFloat = 22
    @FocusState private var queryFocused: Bool

    // MARK: - Catálogo

    /// Os contatos que o app conhece: os remetentes das mensagens que existem,
    /// mais o caderno de endereços. Nenhum filtro por conta, host ou domínio.
    private var pool: [DirectoryContact] {
        QuickReply.directory(messages: store.messages, catalog: Fixtures.contacts)
    }

    private var suggestions: [DirectoryContact] {
        QuickReply.suggestions(matching: query, excluding: to, in: pool)
    }

    private var menuOpen: Bool {
        (queryFocused || seededQuery != nil) && !suggestions.isEmpty
    }

    private var savedLabel: String {
        DraftMeta.savedLabel(savedAt?.formatted(date: .omitted, time: .shortened))
    }

    // MARK: - Corpo

    var body: some View {
        VStack(spacing: 0) {
            if open { card } else { closedCard }
        }
        // Protótipo: `padding: 10px 28px 16px; border-top: 0.5px solid var(--line2)`.
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface.color)
        .hairline(theme.line2, edges: .top)
        .task(id: message.id) { seed() }
    }

    /// Semeia uma vez por mensagem. Um rascunho guardado vence o padrão: quem
    /// já escreveu e fechou a faixa reabre no ponto em que parou.
    private func seed() {
        guard !seeded else { return }
        let draft = store.replyDraft(for: message.id)
        to = Self.seededRecipients(draft: draft, sender: message.from)
        text = draft?.text ?? ""
        savedAt = draft?.savedAt
        open = Self.opensExpanded(for: draft)
        if let seededQuery { query = seededQuery }
        seeded = true
    }

    /// Quem já está no campo "Para" quando a faixa nasce: o que o rascunho
    /// guardou, ou o remetente da mensagem quando não há rascunho.
    ///
    /// Um rascunho **existe** mesmo com "Para" vazio: quem apagou o remetente
    /// de propósito não quer ele de volta na próxima abertura.
    nonisolated static func seededRecipients(draft: ReplyDraft?, sender: Contact) -> [Contact] {
        guard let draft else { return [sender] }
        return draft.to
    }

    /// A faixa nasce aberta — é o estado do protótipo, e é o que preenche o
    /// vazio embaixo da mensagem. A exceção é a resposta que já foi guardada
    /// por "Responder aqui": ali a faixa fechada é o **retorno** daquele
    /// clique, e reabrir sozinha apagaria a única confirmação que existe.
    nonisolated static func opensExpanded(for draft: ReplyDraft?) -> Bool {
        guard let draft, draft.hasText, draft.savedAt != nil else { return true }
        return false
    }

    private func persist() {
        store.setReplyDraft(
            ReplyDraft(to: to, text: text, savedAt: savedAt),
            for: message.id
        )
    }

    // MARK: - Faixa aberta

    /// Protótipo: `border: 0.5px solid var(--line); border-radius: var(--r3);
    /// background: var(--surface2)`. Sem `clipShape`: o menu de sugestões
    /// precisa poder passar por cima da área de escrita, e recortar o cartão
    /// recortaria o menu junto.
    private var card: some View {
        VStack(spacing: 0) {
            toRow
                .zIndex(9)
            editor
            actionRow
            metaRow
        }
        .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.line.color, lineWidth: 0.5)
        }
    }

    /// Protótipo: `padding: 7px 10px 7px 14px; gap: 10px;
    /// border-bottom: 0.5px solid var(--line2)`.
    private var toRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Para")
                .capsLabel()
                .padding(.top, 5)
                .fixedSize()

            recipients

            collapseButton
                .padding(.top, 1)
            promoteButton
                .padding(.top, 1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .hairline(theme.line2, edges: .bottom)
    }

    private var recipients: some View {
        FlowLayout(spacing: 5, rowSpacing: 5, stretchesLast: true) {
            ForEach(to) { contact in
                chip(contact)
            }
            // Protótipo: `min-width: 110px; height: 22px; sans 12.5px`.
            TextField("nome ou email; ", text: $query)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink.color)
                .frame(minWidth: 110, maxWidth: .infinity)
                .frame(height: 22)
                .focused($queryFocused)
                .onSubmit { commitFirstSuggestion() }
                .onChange(of: query) { _, new in resolveSeparator(new) }
                .onKeyPress(.delete) {
                    guard query.isEmpty, !to.isEmpty else { return .ignored }
                    to = Array(to.dropLast())
                    persist()
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard queryFocused else { return .ignored }
                    queryFocused = false
                    return .handled
                }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldHeight = $0 }
        .overlay(alignment: .topLeading) {
            if menuOpen {
                // Protótipo: `top: 28px` para um campo de 22 — 6pt de folga.
                menu.offset(y: fieldHeight + 6)
            }
        }
    }

    /// A mesma etiqueta dos campos das janelas: cápsula de 24pt no acento.
    private func chip(_ contact: Contact) -> some View {
        HStack(spacing: 7) {
            Text(contact.name.isEmpty ? contact.address : contact.name)
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.accentInk.color)
                .lineLimit(1)
            Button {
                to = QuickReply.removing(contact, from: to)
                persist()
            } label: {
                Text("×")
                    .font(theme.sans.font(size: 11))
                    .foregroundStyle(theme.accentInk.color)
                    .frame(width: 15, height: 15)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Tirar \(contact.display)")
        }
        .frame(height: 22)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .background(theme.accentSoft.color)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.accentLine.color, lineWidth: 0.5)
        }
    }

    /// Protótipo: `width: 300px; z-index: 45; border-radius: var(--r3);
    /// box-shadow: 0 18px 40px rgba(0,0,0,0.24)`. Sem a coluna de organização
    /// que o menu das janelas tem: aqui a linha é só avatar, nome e email.
    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(QuickReply.menuLabel(query: query))
                .capsLabel()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 7)
                .padding(.bottom, 5)
                .hairline(theme.line2, edges: .bottom)

            ForEach(suggestions) { suggestion in
                QuickSuggestionRow(suggestion: suggestion) { add(suggestion.contact) }
                    .hairline(theme.line2, edges: .bottom)
            }
        }
        .frame(width: 300)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.line.color, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.24), radius: 20, x: 0, y: 18)
    }

    /// Protótipo: `padding: 14px; min-height: 110px; max-height: 300px;
    /// serif 15px; line-height: 1.65`.
    ///
    /// A altura é **fixa** em 110, não uma faixa de 110 a 300: o `TextEditor`
    /// do SwiftUI não tem altura intrínseca de conteúdo — ele aceita toda a
    /// altura que lhe oferecem — e num `maxHeight` de 300 a faixa comia o corpo
    /// da mensagem, que é exatamente o defeito que esta tarefa existe para
    /// corrigir. Texto mais longo rola dentro do editor, que é o que o
    /// `overflow-y: auto` do protótipo faz depois dos 300.
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .font(theme.serif.font(size: 15))
                .lineSpacing(0.65 * 15)
                .foregroundStyle(theme.ink.color)
                .padding(.horizontal, 14 - 5)  // o TextEditor já traz 5pt de calha
                .padding(.vertical, 14)
                .frame(height: 110, alignment: .top)

            if text.isEmpty {
                Text("Escreva a resposta… ⌘⏎ responde aqui")
                    .font(theme.serif.font(size: 15))
                    .foregroundStyle(theme.ink4.color)
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: text) { _, _ in
            savedAt = nil
            persist()
        }
    }

    /// Protótipo: `padding: 10px 12px 8px; gap: 8px;
    /// border-top: 0.5px solid var(--line2)`.
    private var actionRow: some View {
        HStack(spacing: 8) {
            // Linha 777: `height: 32px; padding: 0 16px; border-radius: var(--r2);
            // background: var(--accent); color: var(--on-accent); 13px/600`.
            ChromeButton(
                appearance: .accent, height: 32, horizontalPadding: 16,
                labelSize: 13, labelWeight: .semibold,
                action: { replyHere() }
            ) {
                HStack(spacing: 8) {
                    Text("Responder aqui")
                    Text("⌘⏎")
                        .font(theme.mono.font(size: 9.5))
                        .opacity(0.75)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .help("Guarda a resposta e fecha a faixa. O Marco 1 não envia pela rede.")

            ChromeButton("Descartar", appearance: .outlined, size: 12.5) { discard() }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .hairline(theme.line2, edges: .top)
    }

    /// Protótipo: `padding: 0 12px 11px`, com `{{ draftCount }} · {{ savedLabel }}`.
    private var metaRow: some View {
        HStack(spacing: 10) {
            Text("\(DraftMeta.countLabel(text)) · \(savedLabel)")
                .capsLabel()
                .lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 11)
    }

    // MARK: - Faixa fechada

    /// O que fica no lugar da faixa depois de "Responder aqui" — e o estado em
    /// que ela pode ser recolhida para devolver altura ao corpo da mensagem.
    ///
    /// Nunca é um beco: diz o que aconteceu com o rascunho e traz o botão que
    /// reabre exatamente onde parou.
    private var closedCard: some View {
        HStack(spacing: 10) {
            if let savedAt {
                Text("✓")
                    .font(theme.sans.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accentInk.color)
                Text(Self.savedNote(
                    words: DraftMeta.countLabel(text),
                    stamp: savedAt.formatted(date: .omitted, time: .shortened)
                ))
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink2.color)
                .lineLimit(1)
            } else {
                Text("Responder a \(message.from.name.isEmpty ? message.from.address : message.from.name)…")
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            ChromeButton(
                savedAt == nil ? "Responder" : "Retomar",
                appearance: .outlined, size: 12.5
            ) {
                open = true
            }
            promoteButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(
            (savedAt == nil ? theme.surface2 : theme.accentSoft).color,
            in: RoundedRectangle(cornerRadius: theme.radiusLarge)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder((savedAt == nil ? theme.line : theme.accentLine).color, lineWidth: 0.5)
        }
    }

    /// "Resposta guardada — 12 palavras · 14:32". Fora da `View` não dá para
    /// testar: um `static` dentro de uma `View` herda o `@MainActor` dela e
    /// trapa quando um teste nonisolated o chama — por isso este fica
    /// `nonisolated`.
    nonisolated static func savedNote(words: String, stamp: String) -> String {
        "Resposta guardada — \(words) · \(stamp)"
    }

    // MARK: - Botões pequenos

    /// Protótipo: `width: 24px; height: 22px; border-radius: var(--r2);
    /// border: 0.5px solid var(--btn-line); background: var(--btn); 11px; ink3`.
    private var promoteButton: some View {
        MiniGlyphButton(glyph: "⤢", help: "Abrir em janela separada") {
            promote()
        }
    }

    private var collapseButton: some View {
        MiniGlyphButton(glyph: "▾", help: "Recolher a faixa de resposta") {
            savedAt = nil
            persist()
            open = false
        }
    }

    // MARK: - Ações

    private func add(_ contact: Contact) {
        to = QuickReply.adding(contact, to: to)
        query = ""
        persist()
    }

    private func commitFirstSuggestion() {
        guard let first = suggestions.first else { return }
        add(first.contact)
    }

    /// Protótipo: terminar com ";" ou "," fecha a etiqueta ali mesmo.
    private func resolveSeparator(_ typed: String) {
        guard typed.hasSuffix(";") || typed.hasSuffix(",") else { return }
        let raw = String(typed.dropLast())
        guard let resolved = QuickReply.resolve(typed: raw, in: pool) else {
            query = ""
            return
        }
        add(resolved.contact)
    }

    /// "Responder aqui". Marco 1 não tem rede, então isto **não envia**: guarda
    /// o rascunho, fecha a faixa e devolve o estado guardado por escrito, com o
    /// caminho de volta ("Retomar"). Um botão que parecesse enviar e não
    /// enviasse seria pior do que não existir.
    private func replyHere() {
        let stamp = Date.now
        savedAt = stamp
        persist()
        queryFocused = false
        open = false
        UNIWindow.logSend(
            "Responderia \"\(message.subject)\" para "
            + "[\(to.map(\.address).joined(separator: ", "))] "
            + "(\(DraftMeta.wordCount(text)) palavras). O rascunho ficou guardado na sessão."
        )
    }

    /// "⤢". A janela cheia lê `store.replyDraft(for:)` — por isso o rascunho é
    /// gravado **antes** de pedir a janela.
    private func promote() {
        persist()
        queryFocused = false
        onPromote(message)
    }

    private func discard() {
        to = [message.from]
        text = ""
        savedAt = nil
        query = ""
        store.setReplyDraft(nil, for: message.id)
    }
}

/// Uma linha do menu da faixa: avatar, nome e email. Protótipo: `gap: 9px;
/// padding: 6px 12px`, nome 12px/590 e email 10.5px em `--ink3`.
private struct QuickSuggestionRow: View {
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
                        .font(theme.sans.font(size: 12, weight: .semibold))  // 590
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                    Text(suggestion.address)
                        .font(theme.sans.font(size: 10.5))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? theme.accentSoft.color : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Os quadradinhos de 24×22 da linha "Para" — o "⤢" e o "▾".
private struct MiniGlyphButton: View {
    @Environment(\.theme) private var theme
    @State private var hovering = false
    let glyph: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(glyph)
                .font(theme.sans.font(size: 11))
                .foregroundStyle(hovering ? theme.accentInk.color : theme.ink3.color)
                .frame(width: 24, height: 22)
                .background(theme.btn.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(
                            hovering ? theme.accent.color : theme.btnLine.color,
                            lineWidth: 0.5
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

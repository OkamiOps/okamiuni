import SwiftUI
import UNIDesign
import UNICore

/// As telas **03 Composer em janela** (linhas 788–1059, 820×660) e
/// **06 Nova mensagem** (linhas 368–587, 820×620) do protótipo.
///
/// Uma `View` só, com dois modos. Elas partilham quase toda a estrutura — barra
/// de título, campos de destinatário com etiquetas e menu, linha de assunto,
/// barra de formatação, faixa de anexos e rodapé — e divergem em seis pontos,
/// todos explícitos aqui:
///
/// | | 03 responder | 06 nova |
/// |---|---|---|
/// | título | "Re: {assunto}" | "Nova mensagem" |
/// | linha "De" | não tem (a conta é o chip da linha "Para") | tem, com seletor de conta |
/// | corpo | rola junto com o histórico citado | ocupa toda a altura livre |
/// | histórico | tem (mostrar/ocultar a mensagem original) | não tem |
/// | rodapé | Enviar · Enviar e arquivar · Salvar · (carimbo) · Voltar ao painel | Enviar · Salvar · (carimbo) · Descartar |
///
/// **Nada é enviado.** Marco 1 não tem rede: "Enviar" fecha a janela e registra
/// no console.
///
/// ## O carimbo do rascunho saiu da barra de formatação
///
/// Na 03 o protótipo pendura "N palavras · não salvo" no fim da faixa da barra.
/// Em 820pt de janela isso rouba ~150pt da faixa, os sete grupos não cabem mais
/// numa linha, a `FlowLayout` quebra e a moldura da faixa fica com o dobro da
/// altura que a borda desenha — o "as box não estão certas" do dono do projeto.
/// A contagem já aparece na barra de título das duas janelas; o carimbo de
/// salvamento passou para o rodapé, onde a 06 já o tinha. As duas janelas ficam
/// iguais e a barra cabe numa linha nos dois tamanhos.
public struct ComposerWindow: View {
    public enum Mode: Hashable, Sendable {
        /// Responder a uma mensagem — a tela 03.
        case reply(messageID: String)
        /// Escrever do zero — a tela 06. `accountID` nulo abre na primeira conta.
        case new(accountID: String?)
    }

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let store: MailStore
    let mode: Mode

    @State private var to: [Contact] = []
    @State private var cc: [Contact] = []
    @State private var bcc: [Contact] = []
    @State private var ccOpen = false
    @State private var bccOpen = false
    @State private var subject = ""
    /// O corpo é **texto rico**. Era uma `String` até a Task W, e por isso a
    /// barra de formatação não tinha seleção sobre a qual agir: ela só
    /// conseguia aplicar `.font(...)` ao editor inteiro.
    @State private var draft = AttributedString("")
    @State private var selection = AttributedTextSelection()
    @State private var fromAccountID: String?
    @State private var attachments: [String] = []
    @State private var savedStamp: String?
    @State private var historyOpen = true
    @State private var seeded = false

    /// Só para verificação: abre um painel da barra sem clique, para dar para
    /// provar fora da tela que as amostras aparecem inteiras.
    let debugOpenPanel: ComposerToolbar.Panel?

    public init(store: MailStore, mode: Mode) {
        self.store = store
        self.mode = mode
        self.debugOpenPanel = nil
    }

    init(store: MailStore, mode: Mode, debugOpenPanel: ComposerToolbar.Panel?) {
        self.store = store
        self.mode = mode
        self.debugOpenPanel = debugOpenPanel
    }

    private var isReply: Bool {
        if case .reply = mode { return true }
        return false
    }

    private var repliedMessage: Message? {
        guard case .reply(let id) = mode else { return nil }
        return store.messages.first { $0.id == id }
    }

    private var account: Account? {
        if let fromAccountID { return store.account(fromAccountID) }
        if let repliedMessage { return store.account(repliedMessage.accountID) }
        return store.accounts.first
    }

    private var accountTint: Color {
        account.flatMap { TokenColor(css: $0.tint(isDark: theme.isDark))?.color } ?? theme.accent.color
    }

    private var plainDraft: String { String(draft.characters) }
    private var draftCount: String { DraftMeta.countLabel(plainDraft) }

    public var body: some View {
        VStack(spacing: 0) {
            WindowTitleBar(title: title) { WindowBarNote(text: draftCount) }

            if !isReply { fromRow }
            toRow
            if ccOpen { copyRow(label: "Cc", placeholder: "quem mais acompanha; ", chips: $cc) }
            if bccOpen { copyRow(label: "Cco", placeholder: "cópia oculta; ", chips: $bcc) }
            subjectRow

            ComposerToolbar(
                reading: ComposerEditor.reading(of: draft, selection: selection),
                openPanel: debugOpenPanel,
                perform: { command in
                    ComposerEditor.perform(command, on: &draft, selection: &selection, theme: theme)
                }
            )
            // Os painéis de cor e realce são `overlay` que descem por cima do
            // editor. O `zIndex` de dentro da barra só ordena os irmãos dela;
            // é aqui, no empilhamento da janela, que ela precisa ficar acima do
            // editor — senão o painel abre e é decepado, e não dá para escolher
            // cor nenhuma.
            .zIndex(20)

            if isReply { replyBody } else { newBody }

            if !attachments.isEmpty { attachmentRow }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.color)
        // A janela pode nascer antes da principal (o macOS restaura as janelas
        // da sessão anterior), e aí o `MailStore` ainda está vazio. Carregar
        // primeiro não basta: a tarefa pode ser cancelada no meio da
        // restauração. Por isso a semeadura tenta de novo a cada chegada de
        // mensagens, e só se dá por feita quando de fato preencheu.
        // A chave inclui o modo: na restauração a cena nasce com o valor ainda
        // nulo e só depois recebe o id da mensagem — sem isso a semeadura
        // aconteceria uma vez só, na versão vazia.
        .task(id: SeedKey(messageCount: store.messages.count, mode: mode)) {
            if store.messages.isEmpty { await store.load() }
            seed()
        }
    }

    private var title: String {
        Self.windowTitle(replyingTo: repliedMessage)
    }

    /// O título da barra. Protótipo: "Re: {sel.subject}" na 03 e o literal
    /// "Nova mensagem" na 06 — e uma resposta a uma mensagem que já saiu da
    /// caixa (arquivada por outra janela, por exemplo) não pode virar "Re: ".
    nonisolated static func windowTitle(replyingTo message: Message?) -> String {
        guard let message, !message.subject.isEmpty else { return "Nova mensagem" }
        return "Re: \(message.subject)"
    }

    /// Preenche o rascunho na primeira vez. Não repete: reabrir a mesma janela
    /// depois de o usuário ter apagado o destinatário não o traz de volta.
    private struct SeedKey: Hashable {
        let messageCount: Int
        let mode: Mode
    }

    private func seed() {
        guard !seeded else { return }
        switch mode {
        case .reply:
            // Sem a mensagem em mãos não há o que semear — e marcar como feito
            // aqui deixaria a janela restaurada sem destinatário nem assunto.
            guard let repliedMessage else { return }
            // A faixa de resposta rápida do leitor grava o que já foi escrito
            // antes de promover para cá; `ComposerSeed` decide quem vence.
            let seed = ComposerSeed.reply(
                to: repliedMessage,
                draft: store.replyDraft(for: repliedMessage.id)
            )
            to = seed.to
            subject = seed.subject
            // `seed.rich` e não `seed.body`: por `String` a formatação que a
            // pessoa aplicou na faixa do leitor se perderia ao promover para cá
            // com o "⤢", e ela não teria como saber por quê.
            if !seed.rich.characters.isEmpty {
                draft = seed.rich
            }
        case .new(let accountID):
            guard !store.accounts.isEmpty else { return }
            fromAccountID = accountID.flatMap { $0.isEmpty ? nil : $0 } ?? store.accounts.first?.id
        }
        seeded = true
    }

    // MARK: - Linhas de cabeçalho

    /// Só na 06. Protótipo: `padding: 11px 18px; background: var(--surface2)`.
    private var fromRow: some View {
        HStack(spacing: 10) {
            Text("De")
                .capsLabel()
                .frame(width: 52, alignment: .leading)

            Picker("Conta que envia", selection: Binding(
                get: { account?.id ?? "" },
                set: { fromAccountID = $0 }
            )) {
                ForEach(store.accounts) { account in
                    Text("\(account.displayName) · \(account.host)").tag(account.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(theme.sans.font(size: 12.5, weight: .medium))
            .fixedSize()

            TintChip(label: account?.host ?? "", tint: accountTint, emphasized: true)

            Spacer(minLength: 8)

            Text("a assinatura muda com a conta")
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink4.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(theme.surface2.color)
        .hairline(theme.line2, edges: .bottom)
    }

    private var toRow: some View {
        HStack(alignment: .top, spacing: 10) {
            RecipientField(
                label: "Para",
                placeholder: isReply ? "nome ou email; " : "comece a digitar um nome; ",
                inputMinWidth: isReply ? 140 : 160,
                menuWidth: 340,
                pool: Fixtures.contacts,
                chips: $to
            )

            MiniToggle(label: "Cc", on: ccOpen) { ccOpen.toggle() }
                .padding(.top, 1)
            MiniToggle(label: "Cco", on: bccOpen) { bccOpen.toggle() }
                .padding(.top, 1)

            // Protótipo: só a 03 mostra o chip da conta aqui — na 06 ele está
            // na linha "De".
            if isReply {
                TintChip(label: account?.host ?? "", tint: accountTint, emphasized: true)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .hairline(theme.line2, edges: .bottom)
        .zIndex(8)
    }

    private func copyRow(label: String, placeholder: String, chips: Binding<[Contact]>) -> some View {
        RecipientField(
            label: label,
            placeholder: placeholder,
            inputMinWidth: 140,
            menuWidth: 330,
            pool: Fixtures.contacts,
            chips: chips
        )
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .hairline(theme.line2, edges: .bottom)
        .zIndex(7)
    }

    /// Protótipo: `padding: 10px 18px`, com o assunto no serifado de 15pt.
    private var subjectRow: some View {
        HStack(spacing: 10) {
            Text("Assunto")
                .capsLabel()
                .frame(width: 52, alignment: .leading)
            TextField(isReply ? "Assunto" : "Sobre o quê?", text: $subject)
                .textFieldStyle(.plain)
                .font(theme.serif.font(size: 15))
                .foregroundStyle(theme.ink.color)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .hairline(theme.line2, edges: .bottom)
    }

    // MARK: - Corpo

    /// 03: o editor tem altura mínima de 200 e **rola junto** com o histórico
    /// citado embaixo dele.
    private var replyBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                editor(minHeight: 200, placeholder: "Escreva a resposta… selecione o texto para formatar")

                VStack(alignment: .leading, spacing: 12) {
                    ChromeButton(
                        appearance: .outlined, height: 26, horizontalPadding: 11,
                        labelSize: 11.5, labelWeight: .medium,
                        action: { historyOpen.toggle() }
                    ) {
                        HStack(spacing: 7) {
                            Text("⋯").font(theme.mono.font(size: 10))
                            Text(historyOpen ? "Ocultar histórico" : "Mostrar histórico (1 mensagem)")
                        }
                    }

                    if historyOpen, let original = repliedMessage {
                        history(original)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 06: o editor ocupa toda a altura livre.
    private var newBody: some View {
        editor(minHeight: 0, placeholder: "Escreva a mensagem…")
            .frame(maxHeight: .infinity)
    }

    /// Protótipo: `padding: 20px 22px; font-size: 16px; line-height: 1.7`,
    /// com o texto-fantasma no mesmo lugar do cursor.
    private func editor(minHeight: CGFloat, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            // Fonte, cor, sublinhado, tachado e alinhamento vêm **do texto**,
            // não de modificadores do editor: é isso que faz a barra pegar só
            // na seleção. O `.font` aqui é apenas o padrão de quem começa a
            // digitar num rascunho ainda sem atributo nenhum.
            //
            // `attributedTextFormattingDefinition` declara o escopo do corpo.
            // Sem ele o `TextEditor` descarta o `BodyStyleAttribute`, que é a
            // única coisa que sabe dizer se um trecho está em negrito.
            TextEditor(text: $draft, selection: $selection)
                // A definição carrega o escopo **e** a altura de linha. Ela
                // ocupa o lugar do `.lineSpacing(corpo * 0.7)` que estava aqui:
                // medido, aquilo pendurava 10,50pt embaixo de cada fragmento
                // menos do último, o cursor ficava com 28,50pt no meio do texto
                // e 18,00pt na última linha, e era o "cursor gigante" que o dono
                // do projeto relatou. Ver `ComposerBodyFormatting`.
                .attributedTextFormattingDefinition(ComposerBodyFormatting())
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .font(theme.serif.font(size: BodyStyle.defaultSize))
                .foregroundStyle(theme.ink.color)
                .padding(.horizontal, 22 - 5)  // o TextEditor já traz 5pt de calha
                .padding(.vertical, 20)
                .frame(minHeight: minHeight, alignment: .top)

            if draft.characters.isEmpty {
                Text(placeholder)
                    .font(theme.serif.font(size: 16))
                    .foregroundStyle(theme.ink4.color)
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(theme.surface.color)
        .onChange(of: draft) { _, _ in savedStamp = nil }
    }

    /// O histórico citado da 03. Protótipo: `border-left: 2px solid var(--line);
    /// padding-left: 16px`, com o corpo original em `--ink3`.
    private func history(_ original: Message) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(original.from.name)
                    .font(theme.sans.font(size: 12.5, weight: .bold))  // CSS 650
                    .foregroundStyle(theme.ink.color)
                Text(original.from.address)
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(theme.ink3.color)
                Spacer(minLength: 8)
                Text(original.receivedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(theme.mono.font(size: 10.5))
                    .foregroundStyle(theme.ink4.color)
            }
            Text(original.subject)
                .font(theme.serif.font(size: 14, weight: .semibold))
                .foregroundStyle(theme.ink2.color)
            ForEach(Array(original.body.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(theme.serif.font(size: 14.5))
                    .lineSpacing(0.62 * 14.5)  // line-height 1.62
                    .foregroundStyle(theme.ink3.color)
                    .frame(maxWidth: 480, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.line.color).frame(width: 2)
        }
    }

    // MARK: - Anexos e rodapé

    private var attachmentRow: some View {
        HStack(spacing: 6) {
            ForEach(attachments, id: \.self) { name in
                AttachmentChip(name: name, size: sizeLabel(for: name)) {
                    attachments.removeAll { $0 == name }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .hairline(theme.line2, edges: .top)
    }

    private func sizeLabel(for name: String) -> String {
        Fixtures.attachments.first { $0.name == name }?.size ?? ""
    }

    private var footer: some View {
        HStack(spacing: 8) {
            AttachButton { addAttachment() }

            ChromeButton(
                appearance: .accent, horizontalPadding: 18,
                labelSize: nil, action: { send(archiving: false) }
            ) {
                HStack(spacing: 8) {
                    Text("Enviar")
                        .font(theme.sans.font(size: 13, weight: .semibold))
                    Text("⌘⏎")
                        .font(theme.mono.font(size: 10))
                        .opacity(0.75)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)

            if isReply {
                ChromeButton("Enviar e arquivar", appearance: .outlined, size: 13) {
                    send(archiving: true)
                }
            }

            ChromeButton("Salvar rascunho", appearance: .outlined) { saveDraft() }

            // O carimbo de salvamento mora no rodapé nas **duas** janelas. Na
            // 03 ele ficava no fim da barra de formatação e a quebrava em duas
            // linhas; ver a nota no topo deste arquivo.
            Spacer(minLength: 8)
            Text(DraftMeta.savedLabel(savedStamp))
                .capsLabel(size: 9.5)
                .lineLimit(1)
            Spacer(minLength: 8)

            if isReply {
                ChromeButton("Voltar ao painel", appearance: .outlined) { dismiss() }
            } else {
                ChromeButton("Descartar", appearance: .outlined) { dismiss() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(theme.surface2.color)
        .hairline(theme.line2, edges: .top)
    }

    // MARK: - Ações

    private func addAttachment() {
        guard let next = Fixtures.attachments.first(where: { !attachments.contains($0.name) }) else { return }
        attachments.append(next.name)
    }

    private func saveDraft() {
        savedStamp = Date.now.formatted(date: .omitted, time: .shortened)
    }

    private func send(archiving: Bool) {
        let recipients = to.map(\.address).joined(separator: ", ")
        UNIWindow.logSend(
            "Enviaria \"\(subject)\" para [\(recipients)] pela conta \(account?.address ?? "—") "
            + "(\(DraftMeta.wordCount(plainDraft)) palavras, \(attachments.count) anexos)"
            + (archiving ? " e arquivaria a original." : ".")
        )
        if archiving, let original = repliedMessage {
            store.move(original, to: .archived)
        }
        dismiss()
    }
}

/// O "Cc"/"Cco" ao lado do campo Para. Protótipo `miniBtn(on)`:
/// `height: 22px; padding: 0 8px; mono 9.5px; letter-spacing: 0.06em`.
private struct MiniToggle: View {
    @Environment(\.theme) private var theme
    let label: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(theme.mono.font(size: 9.5, weight: .medium))
                .tracking(0.06 * 9.5)
                .textCase(.uppercase)
                .foregroundStyle(on ? theme.accentInk.color : theme.ink3.color)
                .frame(height: 22)
                .padding(.horizontal, 8)
                .background(on ? theme.accentSoft.color : theme.btn.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(on ? theme.accent.color : theme.btnLine.color, lineWidth: 0.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
    }
}

/// Protótipo: `width: 32px; height: 32px`, com o clipe em SVG.
private struct AttachButton: View {
    @Environment(\.theme) private var theme
    @State private var hovering = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "paperclip")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(hovering ? theme.accentInk.color : theme.ink2.color)
                .frame(width: 32, height: 32)
                .background(theme.btn.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(hovering ? theme.accent.color : theme.btnLine.color, lineWidth: 0.5)
                }
                .shadow(theme.btnShadow)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .onHover { hovering = $0 }
        .help("Anexar arquivo")
    }
}

/// Protótipo: `height: 28px; padding: 0 6px 0 11px; border-radius: var(--r2)`.
private struct AttachmentChip: View {
    @Environment(\.theme) private var theme
    let name: String
    let size: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink.color)
            Text(size)
                .font(theme.mono.font(size: 9.5))
                .foregroundStyle(theme.ink4.color)
            Button(action: onRemove) {
                Text("×")
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(theme.ink3.color)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(in: Rectangle())
        }
        .frame(height: 28)
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line.color, lineWidth: 0.5)
        }
    }
}

#if os(macOS)
#Preview("03 Composer") {
    ComposerWindow(store: MailStore(source: InMemoryMailSource.fixtures), mode: .reply(messageID: "m1"))
        .environment(ThemeStore())
        .frame(width: 820, height: 660)
}

#Preview("06 Nova mensagem") {
    ComposerWindow(store: MailStore(source: InMemoryMailSource.fixtures), mode: .new(accountID: nil))
        .environment(ThemeStore())
        .frame(width: 820, height: 620)
}
#endif

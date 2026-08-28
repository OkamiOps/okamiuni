import SwiftUI
import UNIDesign
import UNICore

/// A faixa de resposta rápida embutida no leitor — protótipo, tela **01 Caixa
/// unificada**, a partir da linha 1128.
///
/// De cima para baixo, como o protótipo desenha:
///
/// 1. linha `PARA` com etiquetas, campo de busca, **Cc**, **Cco** e o **⤢**;
/// 2. as linhas Cc e Cco, quando abertas;
/// 3. a **barra de formatação**, na variante compacta de `ComposerToolbar` —
///    fonte, corpo, `B I U S`, cor, realce e o `⋯` que abre listas,
///    alinhamento, link e tabela numa segunda linha;
/// 4. a área de escrita, que agora é **texto rico**;
/// 5. os anexos, quando houver;
/// 6. o rodapé: 📎, **Enviar**, **Enviar e arquivar**, **Salvar**;
/// 7. a linha final: **Rascunho sugerido ▾** e `{contagem} · {carimbo}`.
///
/// ## Uma barra só, em dois formatos
///
/// A barra daqui é a **mesma** de `ComposerToolbar` — mesma leitura da seleção,
/// mesmos `ComposerCommand`, mesmo `ComposerEditor` aplicando. A faixa só pede
/// a densidade `.band`, que é o que o protótipo mostra aqui: menos grupos e um
/// `⋯` para o resto. Escrever uma segunda barra faria a faixa e a janela
/// divergirem no primeiro conserto.
///
/// ## Nenhum botão é mudo
///
/// Marco 1 não tem rede. Cada ação faz o que o marco permite **com retorno
/// visível**, ou fica desabilitada com o motivo no `help`:
///
/// - **Enviar** carimba a resposta como pronta, guarda tudo no `MailStore` e
///   fecha a faixa na confirmação — que diz, por escrito, que nada saiu pela
///   rede. Desabilitado sem destinatário ou sem texto.
/// - **Enviar e arquivar** faz o mesmo **e arquiva a original de verdade**, com
///   `store.move(_:to:.archived)`. Essa metade não é simulada: a mensagem sai
///   da caixa e a lista escolhe a próxima.
/// - **Salvar** carimba o rascunho e deixa a faixa aberta; a linha de baixo
///   passa de "não salvo" a "rascunho salvo HH:MM". Desabilitado quando não há
///   nada novo para salvar.
/// - **📎** anexa da mesma lista de exemplo que a janela 03 usa, e cada anexo
///   vira uma etiqueta com × que tira.
struct QuickReplyBand: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let store: MailStore
    let message: Message
    /// O "⤢": promove esta resposta para a janela cheia. Quem recebe já
    /// encontra o rascunho em `store.replyDraft(for:)`.
    let onPromote: (Message) -> Void

    /// Portas do harness de renderização. Ele desenha fora da tela e nunca
    /// entrega foco a ninguém, então sem elas não há como verificar a aparência
    /// do menu de sugestões nem dos painéis da barra. Não mudam nada no app:
    /// os padrões são `nil`/`false`.
    var seededQuery: String?
    /// A mesma porta, para as linhas Cc e Cco: sem ela não há como provar que
    /// a lista **delas** também passa por cima da barra de formatação, e um
    /// empilhamento consertado só no campo "Para" volta no próximo print.
    var seededCopyQuery: String?
    var debugOpenPanel: ComposerToolbar.Panel?
    var debugMoreFormatting = false
    var debugCopiesOpen = false

    @State private var open = true
    @State private var to: [Contact] = []
    @State private var cc: [Contact] = []
    @State private var bcc: [Contact] = []
    @State private var ccOpen = false
    @State private var bccOpen = false
    /// O corpo é **texto rico**. Era `String`, e por isso a faixa não podia ter
    /// barra: uma barra que age sobre a seleção precisa de atributo por trecho.
    @State private var draft = AttributedString("")
    @State private var selection = AttributedTextSelection()
    @State private var attachments: [String] = []
    @State private var savedAt: Date?
    @State private var sentAt: Date?
    @State private var archivedOriginal = false
    @State private var seeded = false

    // MARK: - Catálogo

    /// Os contatos que o app conhece: os remetentes das mensagens que existem,
    /// mais o caderno de endereços. Nenhum filtro por conta, host ou domínio.
    private var pool: [DirectoryContact] {
        QuickReply.directory(messages: store.messages, catalog: Fixtures.contacts)
    }

    private var plainText: String { String(draft.characters) }

    // MARK: - Assinatura

    /// A conta que responde é a que recebeu a mensagem — a faixa não tem
    /// seletor de "De", e o protótipo também não põe um aqui.
    private var account: Account? { store.account(message.accountID) }

    private var signature: String { account?.signature ?? "" }

    private var canInsertSignature: Bool {
        Signature.canInsert(signature, into: plainText)
    }

    /// Controle mudo é defeito: ou ele age, ou diz por que não.
    private var signatureHelp: String {
        if signature.isEmpty {
            return "Inserir assinatura — indisponível: a conta \(account?.host ?? "") não tem assinatura"
        }
        if !canInsertSignature {
            return "Inserir assinatura — a assinatura desta conta já está no fim da resposta"
        }
        return "Inserir a assinatura de \(account?.host ?? "") no fim da resposta"
    }

    private func insertSignature() {
        let style = Signature.style(endingIn: draft)
        draft.transform(updating: &selection) { text in
            Signature.insert(signature, into: &text, style: style)
            ComposerEditor.decorate(&text, theme: theme)
        }
        bodyChanged()
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
        let stored = store.replyDraft(for: message.id)
        to = Self.seededRecipients(draft: stored, sender: message.from)
        cc = stored?.cc ?? []
        bcc = stored?.bcc ?? []
        ccOpen = debugCopiesOpen || !(stored?.cc.isEmpty ?? true)
        bccOpen = debugCopiesOpen || !(stored?.bcc.isEmpty ?? true)
        attachments = stored?.attachments ?? []
        savedAt = stored?.savedAt
        sentAt = stored?.sentAt
        archivedOriginal = stored?.archivedOriginal ?? false
        if var body = stored?.body {
            // O tema pode ter mudado desde que o rascunho foi guardado; a
            // projeção do `BodyStyle` em atributos do SwiftUI é reescrita aqui.
            ComposerEditor.decorate(&body, theme: theme)
            draft = body
        }
        open = Self.opensExpanded(for: stored)
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
    /// vazio embaixo da mensagem. A exceção é a resposta que já passou pelo
    /// "Enviar": ali a faixa fechada é o **retorno** daquele clique, e reabrir
    /// sozinha apagaria a única confirmação que existe.
    ///
    /// "Salvar" **não** fecha: quem salvou continua escrevendo. Por isso
    /// `sentAt` e `savedAt` são campos distintos em `ReplyDraft`.
    nonisolated static func opensExpanded(for draft: ReplyDraft?) -> Bool {
        guard let draft, draft.sentAt != nil else { return true }
        return false
    }

    /// O que a faixa tem agora, no formato que atravessa a fronteira.
    private var currentDraft: ReplyDraft {
        ReplyDraft(
            to: to, cc: cc, bcc: bcc, body: draft, attachments: attachments,
            savedAt: savedAt, sentAt: sentAt, archivedOriginal: archivedOriginal
        )
    }

    /// Traz de volta para o `@State` o que uma das ações decidiu.
    private func absorb(_ updated: ReplyDraft) {
        to = updated.to
        cc = updated.cc
        bcc = updated.bcc
        draft = updated.body
        attachments = updated.attachments
        savedAt = updated.savedAt
        sentAt = updated.sentAt
        archivedOriginal = updated.archivedOriginal
    }

    private func persist() {
        store.setReplyDraft(currentDraft, for: message.id)
    }

    /// Toda escrita no corpo passa por aqui: guarda, e apaga os carimbos, que
    /// deixaram de ser verdade no instante em que o texto mudou.
    private func bodyChanged() {
        absorb(QuickReply.edited(currentDraft))
        persist()
    }

    // MARK: - Faixa aberta

    /// Protótipo: `border: 0.5px solid var(--line); border-radius: var(--r3);
    /// background: var(--surface2)`. Sem `clipShape`: o menu de sugestões e os
    /// painéis de cor precisam poder passar por cima da área de escrita, e
    /// recortar o cartão recortaria os dois junto.
    private var card: some View {
        VStack(spacing: 0) {
            toRow
                .zIndex(9)
            if ccOpen {
                copyRow(label: "Cc", placeholder: "quem mais acompanha; ", chips: $cc)
                    .zIndex(8)
            }
            if bccOpen {
                copyRow(label: "Cco", placeholder: "cópia oculta; ", chips: $bcc)
                    .zIndex(7)
            }
            toolbar
                .zIndex(6)
            editor
            if !attachments.isEmpty { attachmentRow }
            actionRow
            metaRow
        }
        .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
    }

    /// Protótipo: `padding: 7px 10px 7px 14px; gap: 10px;
    /// border-bottom: 0.5px solid var(--line2)`.
    private var toRow: some View {
        BandRecipientRow(
            label: "Para",
            placeholder: "nome ou email; ",
            chips: $to,
            pool: pool,
            seededQuery: seededQuery,
            onChange: persist
        ) {
            MiniToggleButton(label: "Cc", on: ccOpen) {
                ccOpen.toggle()
                if !ccOpen { cc = []; persist() }
            }
            MiniToggleButton(label: "Cco", on: bccOpen) {
                bccOpen.toggle()
                if !bccOpen { bcc = []; persist() }
            }
            collapseButton
            promoteButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .hairline(theme.line2, edges: .bottom)
    }

    /// Protótipo: `padding: 7px 14px` nas linhas Cc e Cco.
    private func copyRow(
        label: String, placeholder: String, chips: Binding<[Contact]>
    ) -> some View {
        BandRecipientRow(
            label: label,
            placeholder: placeholder,
            chips: chips,
            pool: pool,
            seededQuery: seededCopyQuery,
            onChange: persist
        ) {
            EmptyView()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .hairline(theme.line2, edges: .bottom)
    }

    /// A barra da janela, na densidade da faixa. Ela lê a seleção do editor e
    /// emite comandos; quem aplica é `ComposerEditor`, o mesmo das telas 03 e
    /// 06 — a faixa não sabe editar texto.
    private var toolbar: some View {
        ComposerToolbar(
            reading: ComposerEditor.reading(of: draft, selection: selection),
            density: .band,
            openPanel: debugOpenPanel,
            moreOpen: debugMoreFormatting,
            perform: { command in
                ComposerEditor.perform(
                    command, on: &draft, selection: &selection, theme: theme
                )
                bodyChanged()
            }
        )
    }

    /// Protótipo: `padding: 14px; min-height: 110px; max-height: 300px;
    /// serif 15px; line-height: 1.65`.
    ///
    /// A altura é **fixa** em 110, não uma faixa de 110 a 300: o `TextEditor`
    /// do SwiftUI não tem altura intrínseca de conteúdo — ele aceita toda a
    /// altura que lhe oferecem — e num `maxHeight` de 300 a faixa comia o corpo
    /// da mensagem. Texto mais longo rola dentro do editor, que é o que o
    /// `overflow-y: auto` do protótipo faz depois dos 300.
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            // **O mesmo editor da janela**, na mesma densidade de barra. Deixar
            // a faixa no `TextEditor` depois de a janela virar `NSTextView`
            // daria dois comportamentos de formatação dentro do mesmo app — que
            // é pior que o defeito que a Task AF veio consertar.
            //
            // A faixa herda junto o ritmo de 1,7 do modelo. Ela usava
            // `.lineSpacing(0.65 × 15)`, que é o eixo errado: o espaçamento
            // pendura folga **depois** de cada fragmento e não depois do último,
            // e reproduzia na faixa o "cursor gigante" que a janela já tinha
            // consertado. Ver `ComposerTextKit`.
            ComposerTextView(
                text: bodyBinding,
                selection: $selection,
                theme: theme,
                // Protótipo: `padding: 14px`.
                insets: CGSize(width: 14, height: 14)
            )
            .frame(height: 110, alignment: .top)

            if draft.characters.isEmpty {
                // Protótipo, linha 1275.
                Text("Escreva a resposta… selecione o texto para formatar · ⌘⏎ envia")
                    .font(theme.serif.font(size: 15))
                    .foregroundStyle(theme.ink4.color)
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// A escrita do corpo passa toda por este `Binding`, e não por um
    /// `.onChange`: assim a semeadura não conta como edição e não apaga o
    /// carimbo do rascunho que acabou de ser lido do `MailStore`.
    private var bodyBinding: Binding<AttributedString> {
        Binding(
            get: { draft },
            set: { newValue in
                guard newValue != draft else { return }
                draft = newValue
                bodyChanged()
            }
        )
    }

    /// Protótipo: `padding: 8px 12px; gap: 6px; border-top: 0.5px solid var(--line2)`.
    private var attachmentRow: some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            ForEach(attachments, id: \.self) { name in
                BandAttachmentChip(name: name, size: Self.sizeLabel(for: name)) {
                    attachments.removeAll { $0 == name }
                    persist()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .hairline(theme.line2, edges: .top)
    }

    /// Protótipo: `padding: 10px 12px 8px; gap: 8px;
    /// border-top: 0.5px solid var(--line2)`, com 📎, "Enviar ⌘⏎",
    /// "Enviar e arquivar" e "Salvar".
    private var actionRow: some View {
        HStack(spacing: 8) {
            AttachGlyphButton(enabled: canAttach, help: attachHelp) { attach() }

            // Divergência do protótipo, a pedido do dono do projeto: o botão de
            // assinatura não existe no `.dc.html`. Ver `Signature`.
            AttachGlyphButton(
                symbol: "signature", enabled: canInsertSignature, help: signatureHelp
            ) {
                insertSignature()
            }

            ChromeButton(
                appearance: canSend ? .accent : .muted,
                height: 30, horizontalPadding: 16,
                labelSize: nil, action: { send(archiving: false) }
            ) {
                HStack(spacing: 8) {
                    Text("Enviar")
                        .font(theme.sans.font(size: 12.5, weight: .semibold))
                    Text("⌘⏎")
                        .font(theme.mono.font(size: 9.5))
                        .opacity(0.75)
                }
            }
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help(sendHelp)

            ChromeButton(
                "Enviar e arquivar",
                appearance: canSend ? .outlined : .muted,
                size: 12.5, height: 30, horizontalPadding: 14
            ) {
                send(archiving: true)
            }
            .disabled(!canSend)
            .help(archiveHelp)

            ChromeButton(
                "Salvar",
                appearance: canSave ? .outlined : .muted,
                size: 12.5, height: 30, horizontalPadding: 12
            ) {
                saveDraft()
            }
            .disabled(!canSave)
            .help(saveHelp)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .hairline(theme.line2, edges: .top)
    }

    /// Protótipo: `padding: 0 12px 11px`, com o seletor de rascunho sugerido à
    /// esquerda e `{{ draftCount }} · {{ savedLabel }}` à direita.
    private var metaRow: some View {
        HStack(spacing: 10) {
            SuggestedDraftPicker(drafts: QuickReply.suggestedDrafts(for: message)) { suggested in
                use(suggested)
            }
            Spacer(minLength: 8)
            Text("\(DraftMeta.countLabel(plainText)) · \(savedLabel)")
                .capsLabel()
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 11)
    }

    // MARK: - Faixa fechada

    /// O que fica no lugar da faixa depois de "Enviar" — e o estado em que ela
    /// pode ser recolhida para devolver altura ao corpo da mensagem.
    ///
    /// Nunca é um beco: diz o que aconteceu com o rascunho e traz o botão que
    /// reabre exatamente onde parou.
    private var closedCard: some View {
        HStack(spacing: 10) {
            if let sentAt {
                Text("✓")
                    .font(theme.sans.font(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accentInk.color)
                Text(Self.sentNote(
                    words: DraftMeta.countLabel(plainText),
                    stamp: sentAt.formatted(date: .omitted, time: .shortened),
                    archived: archivedOriginal
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
                sentAt == nil ? "Responder" : "Retomar",
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
            (sentAt == nil ? theme.surface2 : theme.accentSoft).color,
            in: RoundedRectangle(cornerRadius: theme.radiusLarge)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(
                    (sentAt == nil ? theme.line : theme.accentLine).color,
                    lineWidth: Hairline.thickness(displayScale)
                )
        }
    }

    /// O retorno visível do "Enviar", e a única coisa na tela que diz o que o
    /// marco de fato fez. Fora da `View` não dá para testar: um `static` dentro
    /// de uma `View` herda o `@MainActor` dela e trapa quando um teste
    /// nonisolated o chama — por isso este fica `nonisolated`.
    nonisolated static func sentNote(words: String, stamp: String, archived: Bool) -> String {
        let head = archived
            ? "Pronta para envio, original arquivada"
            : "Pronta para envio"
        return "\(head) — \(words) · \(stamp) · sem rede neste marco"
    }

    /// A etiqueta de tamanho do anexo, da mesma lista da janela 03.
    nonisolated static func sizeLabel(for name: String) -> String {
        Fixtures.attachments.first { $0.name == name }?.size ?? ""
    }

    // MARK: - Botões pequenos

    /// Protótipo: `width: 24px; height: 22px; border-radius: var(--r2);
    /// border: 0.5px solid var(--btn-line); background: var(--btn); 11px; ink3`.
    private var promoteButton: some View {
        MiniGlyphButton(glyph: "⤢", help: promoteHelp) {
            promote()
        }
    }

    private var collapseButton: some View {
        MiniGlyphButton(glyph: "▾", help: "Recolher a faixa de resposta") {
            persist()
            open = false
        }
    }

    // MARK: - Estado dos botões

    private var hasRecipient: Bool { !to.isEmpty }

    private var hasBody: Bool {
        !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool { QuickReply.canSend(currentDraft) }

    private var sendHelp: String {
        if !hasBody { return "Enviar — indisponível: a resposta ainda está vazia." }
        if !hasRecipient { return "Enviar — indisponível: escolha pelo menos um destinatário." }
        return "Marco 1 não tem rede. Carimba a resposta como pronta, guarda tudo "
            + "e fecha a faixa na confirmação."
    }

    private var archiveHelp: String {
        guard canSend else { return sendHelp }
        return message.bucket == .archived
            ? "A original já está arquivada; a resposta fica pronta para envio."
            : "Arquiva a original de verdade e deixa a resposta pronta para envio."
    }

    private var canSave: Bool { QuickReply.canSave(currentDraft) }

    private var saveHelp: String {
        if let savedAt {
            return "Rascunho já salvo às \(savedAt.formatted(date: .omitted, time: .shortened))."
        }
        guard hasBody || !attachments.isEmpty else {
            return "Salvar — indisponível: não há nada escrito nem anexado."
        }
        return "Guarda o rascunho com carimbo e deixa a faixa aberta."
    }

    private var canAttach: Bool { attachments.count < Fixtures.attachments.count }

    private var attachHelp: String {
        canAttach
            ? "Anexar arquivo"
            : "Anexar — indisponível: a lista de exemplo do Marco 1 acabou."
    }

    private var promoteHelp: String {
        "Abrir em janela separada. O texto vai junto; a formatação ainda não — ver o relatório."
    }

    // MARK: - Ações

    /// "Enviar" e "Enviar e arquivar".
    ///
    /// Marco 1 não tem rede, então isto **não envia**: carimba, guarda, fecha a
    /// faixa e escreve na confirmação que nada saiu. Quando `archiving`, a
    /// metade que o marco consegue fazer acontece de verdade —
    /// `store.move(_:to:.archived)` tira a mensagem da caixa.
    private func send(archiving: Bool) {
        let updated = Self.send(
            currentDraft, for: message, in: store, archiving: archiving, at: .now
        )
        guard updated.sentAt != nil else { return }
        absorb(updated)
        open = false
    }

    /// O que os dois botões de envio de fato fazem, num lugar que o teste
    /// alcança sem clique — o `@MainActor` é do `MailStore`, não da `View`.
    ///
    /// A metade real do "Enviar e arquivar" está aqui: `store.move(_:to:)`
    /// arquiva a original de verdade, tira a mensagem da caixa e a lista
    /// escolhe a próxima. A outra metade, a rede, não existe neste marco — e
    /// por isso o retorno é o carimbo que a faixa fechada mostra por escrito.
    ///
    /// Devolve o rascunho carimbado. Devolve o **original**, sem carimbo,
    /// quando faltava destinatário ou texto: aí o botão está desabilitado e
    /// nada deveria ter chegado até aqui.
    @MainActor
    static func send(
        _ draft: ReplyDraft,
        for message: Message,
        in store: MailStore,
        archiving: Bool,
        at now: Date
    ) -> ReplyDraft {
        guard QuickReply.canSend(draft) else { return draft }
        let stamped = QuickReply.sent(draft, archiving: archiving, at: now)
        store.setReplyDraft(stamped, for: message.id)
        UNIWindow.logSend(
            "Enviaria \"\(message.subject)\" para "
            + "[\(stamped.to.map(\.address).joined(separator: ", "))] "
            + "(\(DraftMeta.wordCount(stamped.text)) palavras, "
            + "\(stamped.attachments.count) anexos)"
            + (archiving ? " e arquivaria a original." : ".")
        )
        // Depois de gravar e registrar: mover a mensagem troca a seleção do
        // leitor, e a faixa some antes de terminar o que estava fazendo.
        if archiving {
            store.move(message, to: .archived)
        }
        return stamped
    }

    private func saveDraft() {
        absorb(QuickReply.saved(currentDraft, at: .now))
        persist()
    }

    private func attach() {
        absorb(QuickReply.attaching(currentDraft, from: Fixtures.attachments.map(\.name)))
        persist()
    }

    /// O "Rascunho sugerido": escreve o texto no corpo, com o estilo padrão.
    /// Substitui o que estiver escrito — é o que o protótipo faz
    /// (`setDraftHtml`), e o menu só aparece com um rótulo por vez.
    private func use(_ suggested: SuggestedDraft) {
        var body = AttributedString(suggested.text)
        body[BodyStyleAttribute.self] = .default
        ComposerEditor.decorate(&body, theme: theme)
        draft = body
        selection = AttributedTextSelection()
        bodyChanged()
    }

    /// "⤢". A janela cheia lê `store.replyDraft(for:)` — por isso o rascunho é
    /// gravado **antes** de pedir a janela.
    private func promote() {
        persist()
        onPromote(message)
    }
}

/// Uma linha de destinatário da faixa: rótulo, etiquetas, campo e o menu de
/// sugestões. As três linhas (Para, Cc, Cco) são a mesma coisa com pool e
/// rótulo diferentes — e cada uma precisa do próprio foco e da própria busca,
/// que é o motivo de ser uma `View` e não um método.
private struct BandRecipientRow<Trailing: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let label: String
    let placeholder: String
    @Binding var chips: [Contact]
    let pool: [DirectoryContact]
    /// Porta do harness: sem foco não há menu, e fora da tela ninguém tem foco.
    var seededQuery: String?
    let onChange: () -> Void
    @ViewBuilder var trailing: Trailing

    @State private var query = ""
    @State private var seeded = false
    @State private var fieldHeight: CGFloat = 22
    @FocusState private var focused: Bool

    private var suggestions: [DirectoryContact] {
        QuickReply.suggestions(matching: query, excluding: chips, in: pool)
    }

    private var menuOpen: Bool {
        (focused || seededQuery != nil) && !suggestions.isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .capsLabel()
                .padding(.top, 5)
                .fixedSize()

            field

            trailing
                .padding(.top, 1)
        }
        .task {
            guard !seeded else { return }
            if let seededQuery { query = seededQuery }
            seeded = true
        }
    }

    private var field: some View {
        FlowLayout(spacing: 5, rowSpacing: 5, stretchesLast: true) {
            ForEach(chips) { contact in
                chip(contact)
            }
            // Protótipo: `min-width: 110px; height: 22px; sans 12.5px`.
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink.color)
                .frame(minWidth: 110, maxWidth: .infinity)
                .frame(height: 22)
                .focused($focused)
                .onSubmit { commitFirstSuggestion() }
                .onChange(of: query) { _, new in resolveSeparator(new) }
                .onKeyPress(.delete) {
                    guard query.isEmpty, !chips.isEmpty else { return .ignored }
                    chips = Array(chips.dropLast())
                    onChange()
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard focused else { return .ignored }
                    focused = false
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
                chips = QuickReply.removing(contact, from: chips)
                onChange()
            } label: {
                Text("×")
                    .font(theme.sans.font(size: 11))
                    .foregroundStyle(theme.accentInk.color)
                    .frame(width: 15, height: 15)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusRing(in: Circle())
            .help("Tirar \(contact.display)")
        }
        .frame(height: 22)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .background(theme.accentSoft.color)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.accentLine.color, lineWidth: Hairline.thickness(displayScale))
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
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .shadow(color: .black.opacity(0.24), radius: 20, x: 0, y: 18)
    }

    private func add(_ contact: Contact) {
        chips = QuickReply.adding(contact, to: chips)
        query = ""
        onChange()
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
        .focusRing(in: Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Os quadradinhos de 24×22 da linha "Para" — o "⤢" e o "▾".
private struct MiniGlyphButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
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
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// O "Cc"/"Cco" da linha "Para". Protótipo `miniBtn(on)`: `height: 22px;
/// padding: 0 8px; mono 9.5px; letter-spacing: 0.06em`.
private struct MiniToggleButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
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
                        .strokeBorder(
                            on ? theme.accent.color : theme.btnLine.color,
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .help(on ? "Fechar a linha \(label)" : "Abrir a linha \(label)")
    }
}

/// O 📎 do rodapé da faixa. Protótipo: `width: 30px; height: 30px`.
private struct AttachGlyphButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @State private var hovering = false
    /// O 📎 é o padrão; a assinatura reusa o mesmo botão com outro glifo, em
    /// vez de um controle novo ao lado que leria como enxerto.
    var symbol: String = "paperclip"
    let enabled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 30, height: 30)
                .background(enabled ? theme.btn.color : theme.surface3.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(border, lineWidth: Hairline.thickness(displayScale))
                }
                .shadow(enabled ? theme.btnShadow : [])
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var foreground: Color {
        guard enabled else { return theme.ink4.color.opacity(0.55) }
        return hovering ? theme.accentInk.color : theme.ink2.color
    }

    private var border: Color {
        guard enabled else { return theme.line.color }
        return hovering ? theme.accent.color : theme.btnLine.color
    }
}

/// Protótipo: `height: 26px; padding: 0 6px 0 10px; border-radius: var(--r2)`,
/// com nome, tamanho em mono e o × que tira.
private struct BandAttachmentChip: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let name: String
    let size: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
            Text(size)
                .font(theme.mono.font(size: 9.5))
                .foregroundStyle(theme.ink4.color)
            Button(action: onRemove) {
                Text("×")
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(theme.ink3.color)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(in: Rectangle())
            .help("Tirar \(name)")
        }
        .frame(height: 26)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
    }
}

/// "Rascunho sugerido ▾". Protótipo: `height: 30px; border: 0.5px dashed
/// var(--accent-line); background: transparent; color: var(--accent-ink)`.
private struct SuggestedDraftPicker: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let drafts: [SuggestedDraft]
    let pick: (SuggestedDraft) -> Void

    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Text("Rascunho sugerido")
                    .font(theme.sans.font(size: 12, weight: .medium))  // CSS 550
                Text("▾")
                    .font(theme.sans.font(size: 8))
            }
            .foregroundStyle(theme.accentInk.color)
            .frame(height: 30)
            .padding(.leading, 11)
            .padding(.trailing, 11)
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(
                        theme.accentLine.color,
                        style: StrokeStyle(
                            lineWidth: Hairline.thickness(displayScale),
                            dash: [4, 3]
                        )
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .fixedSize()
        .help("Preencher a resposta com um rascunho sugerido")
        .popover(isPresented: $open, arrowEdge: .top) { panel }
    }

    /// Era um `Menu` do SwiftUI, que é um `NSMenu`: a moldura tracejada e a
    /// tinta do acento ficavam no gatilho, mas a lista que abria era a do
    /// sistema. Agora ela é desenhada aqui, no mesmo painel dos outros menus da
    /// barra — ver `ComposerSelect`, que documenta a decisão inteira.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(drafts) { draft in
                Button {
                    pick(draft)
                    open = false
                } label: {
                    Text(draft.label)
                        .font(theme.sans.font(size: 12.5))
                        .foregroundStyle(theme.ink.color)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.radiusSmall)
            }
        }
        .padding(8)
        .frame(width: 280)
        .background(theme.surface.color)
    }
}

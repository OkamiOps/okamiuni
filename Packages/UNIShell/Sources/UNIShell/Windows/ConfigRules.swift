import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// Regras: a frase em português no alto, as regras lidas como frases, e a
/// página de uma regra nova com a prévia do que ela pegaria.
struct ConfigRules: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale

    let store: EmailRuleStore?
    let accounts: [AccountStatus]
    let moveDestinations: [SwipeMoveDestination]
    let messages: [Message]
    let textAssistant: (any TextAssisting)?
    /// `true` enquanto a página é "Nova regra".
    @Binding var composing: Bool

    @State private var sentence = ""
    @State private var draft = ConfigRuleDraft()
    @State private var composerSource: ConfigRuleComposer.Source?
    @State private var composing_ = false
    @State private var working = false
    @State private var showingAllMatches = false
    @State private var forwardingConfirmation = false
    @State private var editingTerms = false
    @State private var termsText = ""
    @State private var now = Date()

    var body: some View {
        Group {
            if let store {
                if composing {
                    newRule(store)
                } else {
                    list(store)
                }
            } else {
                Text(L10n.tr("O armazenamento de regras não foi conectado a esta janela."))
                    .font(theme.sans.font(size: 13))
                    .foregroundStyle(palette.ink3.color)
            }
        }
        .confirmationDialog(
            L10n.tr("Ativar encaminhamento automático?"),
            isPresented: $forwardingConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Salvar e ativar encaminhamento")) { commit() }
            Button(L10n.tr("Cancelar"), role: .cancel) {}
        } message: {
            Text(L10n.tr("Mensagens novas que corresponderem a esta regra serão encaminhadas para \(draft.forwardTo ?? ""), pela conta escolhida, sem anexos, Cc ou Cco."))
        }
    }

    // MARK: A lista

    private func list(_ store: EmailRuleStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                naturalLanguageField(value: $sentence, action: L10n.tr("Montar regra"))
                Text(L10n.tr("A IA monta, você confere o que ela pegaria, e só então salva."))
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(palette.ink3.color)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                if store.rules.isEmpty {
                    Text(L10n.tr("Nenhuma regra ainda. Descreva uma acima, ou monte à mão."))
                        .font(theme.sans.font(size: 13))
                        .foregroundStyle(palette.ink3.color)
                        .padding(.vertical, 14)
                } else {
                    ForEach(store.rules) { rule in ruleRow(rule, store: store) }
                }

                Text(L10n.tr("Valem para e-mails novos, na ordem da lista. O encaminhar automático sempre confirma com você antes."))
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.ink3.color)
                    .padding(.top, 14)
                    .overlay(alignment: .top) { divider }
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: ConfigMetrics.contentMaxWidth, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func ruleRow(_ rule: EmailRule, store: EmailRuleStore) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.name.isEmpty ? rule.title : rule.name)
                    .font(theme.sans.font(size: 14.5, weight: .semibold))
                    .foregroundStyle(palette.ink.color)
                sentenceText(for: rule)
            }
            Spacer(minLength: 0)
            Text(statLine(rule))
                .font(theme.mono.font(size: 12))
                .foregroundStyle(palette.ink3.color)
            ConfigSwitch(
                isOn: Binding(
                    get: { store.rule(id: rule.id)?.enabled ?? false },
                    set: { store.setEnabled($0, for: rule.id) }
                ),
                label: rule.name
            )
        }
        .padding(.vertical, 14)
        .opacity(rule.enabled ? 1 : 0.6)
        .overlay(alignment: .top) { divider }
        .contextMenu {
            Button(L10n.tr("Editar nesta frase")) { edit(rule) }
            Button(L10n.tr("Apagar regra"), role: .destructive) { store.remove(id: rule.id) }
        }
    }

    /// "Quando {condição}, **{consequência}** · {alcance}". A regra lida como
    /// uma frase, que é a mudança de leitura que o desenho pede — antes era
    /// "Remetente: x · conta · Move: y".
    private func sentenceText(for rule: EmailRule) -> some View {
        let condition: String
        switch rule.condition {
        case .senderContains(let value): condition = L10n.tr("o remetente contém “\(value)”")
        case .subjectContains(let value): condition = L10n.tr("o assunto contém “\(value)”")
        }
        var consequences: [String] = rule.actions.map(\.label)
        if let destination = rule.moveDestination {
            consequences.insert(L10n.tr("mover para \(destination.displayName)"), at: 0)
        }
        if let forwarding = rule.forwarding {
            consequences.append(L10n.tr("encaminhar para \(forwarding.address)"))
        }
        let scope = rule.accountID.flatMap { id in
            accounts.first { $0.accountID == id }?.address
        } ?? L10n.tr("todas as contas")
        let forwards = rule.forwarding != nil
        return (
            Text(L10n.tr("Quando ") + condition + ", ")
                .foregroundStyle(palette.ink2.color)
            + Text(consequences.joined(separator: L10n.tr(" e ")).lowercased())
                .font(theme.sans.font(size: 13.5, weight: .semibold))
                .foregroundStyle((forwards ? palette.orange : palette.ink).color)
            + Text(" · " + (forwards ? L10n.tr("confirma antes") : scope))
                .foregroundStyle(palette.ink3.color)
        )
        .font(theme.sans.font(size: 13.5))
        .lineSpacing(13.5 * 0.45)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Quantas mensagens das que este Mac tem esta regra pegaria nos últimos
    /// sete dias. É contagem **medida**, não estimativa.
    private func statLine(_ rule: EmailRule) -> String {
        var measured = rule
        measured.enabled = true
        let limite = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let count = messages
            .filter { $0.receivedAt >= limite }
            .count { EmailRuleMatcher.matches(measured, message: $0) }
        if !rule.enabled { return L10n.tr("desligada") }
        return L10n.tr("\(count) / semana")
    }

    // MARK: A regra nova

    private func newRule(_ store: EmailRuleStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                naturalLanguageField(value: $sentence, action: L10n.tr("Montar de novo"))

                VStack(alignment: .leading, spacing: 8) {
                    Text(composedNote)
                        .font(theme.sans.font(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.ink2.color)
                    assembledSentence
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)

                matchPreview
                footer(store)
            }
            .frame(maxWidth: ConfigMetrics.contentMaxWidth, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var composedNote: String {
        switch composerSource {
        case .assistant: L10n.tr("Ela montou assim — clique em qualquer parte para ajustar")
        case .local: L10n.tr("Montada aqui no Mac pelo que a frase diz — clique em qualquer parte para ajustar")
        case nil: L10n.tr("Monte clicando em cada parte da frase")
        }
    }

    /// A frase montada, com cada parte ajustável — sublinhado tracejado no
    /// acento, como o desenho.
    private var assembledSentence: some View {
        FlowLayout(spacing: 6, rowSpacing: 8) {
            plain(L10n.tr("Quando chegar e-mail"))
            part(scopeLabel) {
                Button(L10n.tr("em qualquer conta")) { draft.accountID = nil }
                ForEach(accounts) { account in
                    Button(account.address) { draft.accountID = account.accountID }
                }
            }
            plain(draft.field == .sender ? L10n.tr("com remetente contendo") : L10n.tr("com assunto contendo"))
            Button { termsText = draft.terms.joined(separator: ", "); editingTerms = true } label: {
                partLabel(termsLabel)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $editingTerms) { termsEditor }
            plain(":")
            part(consequenceLabel) {
                ForEach(EmailRuleAction.allCases) { action in
                    Button(action.label) {
                        if draft.actions.contains(action) {
                            draft.actions.remove(action)
                        } else {
                            draft.actions.insert(action)
                        }
                    }
                }
                if !moveDestinationsForScope.isEmpty {
                    Divider()
                    ForEach(moveDestinationsForScope) { destination in
                        Button(L10n.tr("mover para \(destination.displayName)")) {
                            draft.moveDestination = destination
                            draft.accountID = destination.accountID
                        }
                    }
                    if draft.moveDestination != nil {
                        Button(L10n.tr("não mover")) { draft.moveDestination = nil }
                    }
                }
            }
            plain(".")
        }
    }

    private func plain(_ text: String) -> some View {
        Text(text)
            .font(theme.sans.font(size: 16))
            .foregroundStyle(palette.ink.color)
    }

    private func part<Content: View>(
        _ label: String, @ViewBuilder menu: () -> Content
    ) -> some View {
        Menu { menu() } label: { partLabel(label) }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }

    private func partLabel(_ label: String) -> some View {
        Text(label)
            .font(theme.sans.font(size: 16, weight: .semibold))
            .foregroundStyle(palette.ink.color)
            .overlay(alignment: .bottom) {
                // `border-bottom: 1.5px dashed accentInk`
                Rectangle()
                    .fill(palette.accentInk.color)
                    .frame(height: 1.5)
                    .mask(alignment: .leading) {
                        GeometryReader { proxy in
                            HStack(spacing: 2.5) {
                                ForEach(0..<Int(proxy.size.width / 5.5) + 1, id: \.self) { _ in
                                    Rectangle().frame(width: 3)
                                }
                            }
                        }
                    }
                    .offset(y: 3)
            }
    }

    private var termsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("O que procurar, separado por vírgula"))
                .font(theme.sans.font(size: 12.5, weight: .semibold))
                .foregroundStyle(palette.ink2.color)
            TextField("nota fiscal, NF-e, boleto", text: $termsText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            ConfigSegmented(
                options: [
                    (ConfigRuleDraft.Field.subject, L10n.tr("no assunto")),
                    (ConfigRuleDraft.Field.sender, L10n.tr("no remetente")),
                ],
                selection: Binding(get: { draft.field }, set: { draft.field = $0 })
            )
            HStack {
                Spacer(minLength: 0)
                Button(L10n.tr("Pronto")) {
                    draft.terms = termsText
                        .components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    editingTerms = false
                }
                .buttonStyle(.plain)
                .configPrimaryButton(
                    palette, font: theme.sans.font(size: 13, weight: .semibold),
                    radius: 9, horizontal: 13, vertical: 7
                )
            }
        }
        .padding(16)
    }

    /// A prévia: quantas mensagens reais a regra pegaria, e uma amostra.
    private var matchPreview: some View {
        let matches = ConfigRuleComposer.matches(draft, in: messages, days: 7, now: now)
        let sample = showingAllMatches ? matches : Array(matches.prefix(3))
        // "nenhum e-mail de gente" é uma promessa verificável: uma mensagem
        // cuja categoria é `primary` (ou que não foi categorizada) é de gente
        // até prova em contrário, e a prévia conta quantas são.
        let people = matches.filter { ($0.category ?? .primary) == .primary }
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L10n.tr("Pegaria \(matches.count) e-mails"))
                    .font(theme.sans.font(size: 14, weight: .semibold))
                    .foregroundStyle(palette.ink.color)
                Text(L10n.tr("dos últimos 7 dias — uma amostra:"))
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.ink3.color)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Circle()
                        .fill((people.isEmpty ? palette.green : palette.orange).color)
                        .frame(width: 7, height: 7)
                    Text(people.isEmpty
                         ? L10n.tr("nenhum e-mail de gente")
                         : L10n.tr("\(people.count) de gente"))
                        .font(theme.sans.font(size: 12.5))
                        .foregroundStyle((people.isEmpty ? palette.green : palette.orange).color)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.tile.color)
            .overlay(alignment: .bottom) { divider }

            if matches.isEmpty {
                Text(L10n.tr("Nada nos últimos 7 dias casa com esta regra. Ela continua valendo para o que chegar."))
                    .font(theme.sans.font(size: 13))
                    .foregroundStyle(palette.ink3.color)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(sample) { sampleRow($0) }
                if matches.count > sample.count {
                    Button(L10n.tr("ver os outros \(matches.count - sample.count)")) {
                        showingAllMatches = true
                    }
                    .buttonStyle(.plain)
                    .font(theme.sans.font(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.accentInk.color)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.tileEdge.color, lineWidth: Hairline.thickness(displayScale))
        }
    }

    private func sampleRow(_ message: Message) -> some View {
        HStack(spacing: 13) {
            Text(message.from.initials.prefix(1).uppercased())
                .font(theme.sans.font(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 30, height: 30)
                .background(palette.accent.color, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(message.from.name.isEmpty ? message.from.address : message.from.name)
                    .font(theme.sans.font(size: 13.5, weight: .semibold))
                    .foregroundStyle(palette.ink.color)
                    .lineLimit(1)
                Text(message.subject)
                    .font(theme.sans.font(size: 13))
                    .foregroundStyle(palette.ink2.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(message.receivedAt, format: .dateTime.weekday(.abbreviated))
                    .font(theme.mono.font(size: 11.5))
                    .foregroundStyle(palette.ink3.color)
                if let destination = draft.moveDestination {
                    Text("→ \(destination.displayName)")
                        .font(theme.sans.font(size: 11.5))
                        .foregroundStyle(palette.ink3.color)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { divider }
    }

    private func footer(_ store: EmailRuleStore) -> some View {
        HStack(spacing: 16) {
            Text(L10n.tr("Vale para os novos. Os que já chegaram ficam onde estão."))
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(palette.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L10n.tr("Cancelar")) { composing = false }
                .buttonStyle(.plain)
                .font(theme.sans.font(size: 13.5))
                .foregroundStyle(palette.ink3.color)
            Button(L10n.tr("Criar regra")) {
                if draft.forwardTo != nil {
                    forwardingConfirmation = true
                } else {
                    commit()
                }
            }
            .buttonStyle(.plain)
            .configPrimaryButton(
                palette, font: theme.sans.font(size: 13.5, weight: .semibold),
                radius: 10, horizontal: 18, vertical: 11
            )
            .disabled(!draft.isValid)
        }
        .padding(.top, 4)
    }

    // MARK: A frase em português

    private func naturalLanguageField(value: Binding<String>, action: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.accentInk.color)
            TextField(
                L10n.tr("Descreva em português: “tudo que vier do contador vai para Financeiro”"),
                text: value
            )
            .textFieldStyle(.plain)
            .font(theme.sans.font(size: 14))
            .foregroundStyle(palette.ink.color)
            .onSubmit { compose() }
            Button(working ? L10n.tr("Montando…") : action) { compose() }
                .buttonStyle(.plain)
                .font(theme.sans.font(size: 13, weight: .semibold))
                .foregroundStyle(palette.accentInk.color)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(palette.accentSoft.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .disabled(working || value.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .configCard(palette, radius: 14)
    }

    // MARK: As ações

    private func compose() {
        let text = sentence.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !working else { return }
        working = true
        Task {
            var result = ConfigRuleComposer.parseLocally(
                text, accounts: accounts, destinations: moveDestinations
            )
            var source = ConfigRuleComposer.Source.local
            if let textAssistant {
                let prompt = ConfigRuleComposer.prompt(
                    for: text,
                    accounts: accounts.map(\.accountID),
                    folders: moveDestinations.map(\.displayName)
                )
                if let answer = try? await textAssistant.answer(
                    question: prompt,
                    in: AssistantConversationSnapshot(mailContext: Self.emptyContext)
                ), let parsed = ConfigRuleComposer.parseAssistantAnswer(
                    answer, accounts: accounts, destinations: moveDestinations
                ) {
                    result = parsed
                    source = .assistant
                }
            }
            draft = result
            composerSource = source
            working = false
            composing = true
            showingAllMatches = false
            now = Date()
        }
    }

    private func edit(_ rule: EmailRule) {
        draft = ConfigRuleDraft(rule)
        composerSource = nil
        sentence = ""
        composing = true
    }

    private func commit() {
        guard let store, draft.isValid else { return }
        for rule in draft.rules { store.upsert(rule) }
        composing = false
        sentence = ""
        draft = ConfigRuleDraft()
        composerSource = nil
    }

    // MARK: Os rótulos da frase

    private var scopeLabel: String {
        guard let accountID = draft.accountID else { return L10n.tr("em qualquer conta") }
        return accounts.first { $0.accountID == accountID }?.address ?? accountID
    }

    private var termsLabel: String {
        guard !draft.terms.isEmpty else { return L10n.tr("algo que você escolher") }
        return draft.terms.map { "“\($0)”" }.joined(separator: L10n.tr(" ou "))
    }

    private var consequenceLabel: String {
        var parts: [String] = []
        if let destination = draft.moveDestination {
            parts.append(L10n.tr("mover para \(destination.displayName)"))
        }
        parts += EmailRuleAction.allCases.filter(draft.actions.contains).map { $0.label.lowercased() }
        if let forwardTo = draft.forwardTo {
            parts.append(L10n.tr("encaminhar para \(forwardTo)"))
        }
        return parts.isEmpty ? L10n.tr("fazer o quê?") : parts.joined(separator: L10n.tr(" e "))
    }

    private var moveDestinationsForScope: [SwipeMoveDestination] {
        guard let accountID = draft.accountID else { return moveDestinations }
        return moveDestinations.filter { $0.accountID == accountID }
    }

    private var divider: some View {
        Rectangle().fill(palette.line.color).frame(height: Hairline.thickness(displayScale))
    }

    /// A montagem da regra não lê e-mail nenhum: o pedido é só a frase. O
    /// contexto vai vazio de propósito — nada da caixa sai daqui por causa
    /// deste botão.
    private static let emptyContext = AssistantMailContext.workspace(
        AssistantWorkspaceContext(
            accounts: [], emailCount: 0, unreadCount: 0,
            mailboxes: [], emails: [], agenda: []
        )
    )
}

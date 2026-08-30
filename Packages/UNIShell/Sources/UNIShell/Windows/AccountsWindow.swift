import SwiftUI
import UNICore
import UNIDesign
import UNISync

public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case accounts
    case intelligence
    case gestures
    case signatures
    case rules

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "Geral"
        case .accounts: "Contas"
        case .intelligence: "Inteligência"
        case .gestures: "Gestos"
        case .signatures: "Assinaturas"
        case .rules: "Regras"
        }
    }

    var symbol: String {
        switch self {
        case .general: "rectangle.3.group"
        case .accounts: "at"
        case .intelligence: "sparkles"
        case .gestures: "hand.draw"
        case .signatures: "signature"
        case .rules: "arrow.triangle.branch"
        }
    }

    /// A barra lateral organiza decisões pela tarefa da pessoa, e não por
    /// como o app implementa cada uma delas. Isso deixa seis seções fáceis de
    /// percorrer sem recorrer a uma busca que esconderia opções importantes.
    var navigationGroup: String {
        switch self {
        case .general, .accounts: "ESTE MAC"
        case .intelligence, .gestures: "COMO O OKAMIUNI TRABALHA"
        case .signatures, .rules: "SEU E-MAIL"
        }
    }

    var summary: String {
        switch self {
        case .general: "Ambiente e preferências"
        case .accounts: "Caixas conectadas"
        case .intelligence: "Assistente e instruções"
        case .gestures: "Arrastar mensagens"
        case .signatures: "Identidade por conta"
        case .rules: "Organização automática"
        }
    }
}

/// Configurações de contas em duas colunas: a conta continua visível enquanto
/// a pessoa lê o estado e age sobre ela. É a organização do Mail do macOS,
/// aplicada aos componentes e tokens do OkamiUNI.
public struct AccountsWindow: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    private let model: AccountsModel
    private let assistantSettings: AssistantSettingsStore?
    private let assistantCredentials: (any AssistantCredentialStore)?
    private let textAssistant: (any OnDeviceTextAssisting)?
    private let liteLLMOAuthAuthorizer: (any LiteLLMOAuthAuthorizing)?
    private let providerOAuthAuthorizer: (any AssistantProviderOAuthAuthorizing)?
    private let emailRules: EmailRuleStore?
    private let themes: ThemeStore?
    private let swipes: SwipeSettingsStore?
    /// A mesma lista de pastas que a caixa de entrada já conhece. Ela é
    /// opcional para manter os ensaios e consumidores antigos da janela sem
    /// uma fonte de mensagens; quando existe, Gestos consegue oferecer
    /// destinos concretos em vez de pedir que a pessoa digite um nome.
    private let mailStore: MailStore?
    @State private var selectedSection: SettingsSection
    @State private var selectedAccountID: String?
    @State private var addingAccount = false
    @State private var removendo: String?

    public init(
        model: AccountsModel,
        initialSection: SettingsSection = .accounts,
        assistantSettings: AssistantSettingsStore? = nil,
        assistantCredentials: (any AssistantCredentialStore)? = nil,
        textAssistant: (any OnDeviceTextAssisting)? = nil,
        liteLLMOAuthAuthorizer: (any LiteLLMOAuthAuthorizing)? = nil,
        providerOAuthAuthorizer: (any AssistantProviderOAuthAuthorizing)? = nil,
        emailRules: EmailRuleStore? = nil,
        themes: ThemeStore? = nil,
        swipes: SwipeSettingsStore? = nil,
        mailStore: MailStore? = nil
    ) {
        self.model = model
        self.assistantSettings = assistantSettings
        self.assistantCredentials = assistantCredentials
        self.textAssistant = textAssistant
        self.liteLLMOAuthAuthorizer = liteLLMOAuthAuthorizer
        self.providerOAuthAuthorizer = providerOAuthAuthorizer
        self.emailRules = emailRules
        self.themes = themes
        self.swipes = swipes
        self.mailStore = mailStore
        _selectedSection = State(initialValue: initialSection)
        _selectedAccountID = State(initialValue: model.statuses.first?.accountID)
    }

    public var body: some View {
        VStack(spacing: 0) {
            WindowTitleBar(title: "Configurações")
            HStack(spacing: 0) {
                settingsSidebar.frame(width: 218)
                Rectangle()
                    .fill(theme.line.color)
                    .frame(width: Hairline.thickness(displayScale))
                settingsContent
            }
        }
        .background(theme.paper.color)
        .tint(theme.accent.color)
        .task { await model.start() }
        .onChange(of: model.statuses) { _, statuses in
            guard !addingAccount else { return }
            if selectedAccountID == nil
                || !statuses.contains(where: { $0.accountID == selectedAccountID }) {
                selectedAccountID = statuses.first?.accountID
            }
        }
        .confirmationDialog(
            "Remover esta conta?",
            isPresented: Binding(get: { removendo != nil }, set: { if !$0 { removendo = nil } })
        ) {
            Button("Remover", role: .destructive) {
                if let id = removendo { Task { await model.remove(id) } }
                removendo = nil
            }
            Button("Cancelar", role: .cancel) { removendo = nil }
        } message: {
            Text("As mensagens já baixadas e a senha guardada no Keychain serão apagadas. A conta no servidor não é tocada.")
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("CENTRAL DE CONTROLE")
                    .capsLabel(size: 9.5)
                Text("Seu e-mail,\ndo seu jeito.")
                    .font(theme.sans.font(size: 17, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Escolha o que quer ajustar. As mudanças ficam neste Mac até você salvá-las.")
                    .font(theme.sans.font(size: 10.5))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 19)
            .padding(.bottom, 17)

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(["ESTE MAC", "COMO O OKAMIUNI TRABALHA", "SEU E-MAIL"], id: \.self) { group in
                        settingsNavigationGroup(group)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 16)
            }

            Spacer(minLength: 0)
        }
        .background(theme.surface2.color)
    }

    private func settingsNavigationGroup(_ group: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(group)
                .capsLabel(size: 8.5)
                .padding(.horizontal, 8)
                .padding(.bottom, 3)

            ForEach(SettingsSection.allCases.filter { $0.navigationGroup == group }) { section in
                settingsNavigationButton(section)
            }
        }
    }

    private func settingsNavigationButton(_ section: SettingsSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 19, height: 19)
                    .foregroundStyle(isSelected ? theme.accent.color : theme.ink3.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.label)
                        .font(theme.sans.font(size: 12, weight: .semibold))
                    Text(section.summary)
                        .font(theme.sans.font(size: 9.5))
                        .foregroundStyle(isSelected ? theme.ink3.color : theme.ink4.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Circle()
                        .fill(theme.accent.color)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(isSelected ? theme.ink.color : theme.ink2.color)
            .padding(.horizontal, 9)
            .frame(minHeight: 47)
            .background(
                isSelected ? theme.surface3.color : Color.clear,
                in: RoundedRectangle(cornerRadius: theme.radiusSmall)
            )
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .accessibilityHint(section.summary)
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selectedSection {
        case .accounts:
            HStack(spacing: 0) {
                accountsSidebar.frame(width: 218)
                Rectangle()
                    .fill(theme.line.color)
                    .frame(width: Hairline.thickness(displayScale))
                accountsDetail
            }
        case .general:
            sectionPane(
                title: "Geral",
                subtitle: "O espaço de trabalho deste Mac"
            ) {
                GeneralSettingsView(
                    scope: .general,
                    settingsStore: assistantSettings,
                    credentialStore: assistantCredentials,
                    textAssistant: textAssistant,
                    liteLLMOAuthAuthorizer: liteLLMOAuthAuthorizer,
                    providerOAuthAuthorizer: providerOAuthAuthorizer,
                    themes: themes,
                    swipes: swipes,
                    moveDestinations: swipeMoveDestinations
                )
            }
        case .intelligence:
            sectionPane(
                title: "Inteligência",
                subtitle: "Conexão, modelo e modo de escrever"
            ) {
                GeneralSettingsView(
                    scope: .intelligence,
                    settingsStore: assistantSettings,
                    credentialStore: assistantCredentials,
                    textAssistant: textAssistant,
                    liteLLMOAuthAuthorizer: liteLLMOAuthAuthorizer,
                    providerOAuthAuthorizer: providerOAuthAuthorizer,
                    themes: themes,
                    swipes: swipes,
                    moveDestinations: swipeMoveDestinations
                )
            }
        case .gestures:
            sectionPane(
                title: "Gestos",
                subtitle: "Ações rápidas para manter a caixa de entrada limpa"
            ) {
                GeneralSettingsView(
                    scope: .gestures,
                    settingsStore: assistantSettings,
                    credentialStore: assistantCredentials,
                    textAssistant: textAssistant,
                    liteLLMOAuthAuthorizer: liteLLMOAuthAuthorizer,
                    providerOAuthAuthorizer: providerOAuthAuthorizer,
                    themes: themes,
                    swipes: swipes,
                    moveDestinations: swipeMoveDestinations
                )
            }
        case .signatures:
            sectionPane(
                title: "Assinaturas",
                subtitle: "Assinaturas de e-mail por conta"
            ) { SignatureSettingsView(model: model) }
        case .rules:
            sectionPane(
                title: "Regras",
                subtitle: "Automatize a organização das mensagens recebidas"
            ) {
                RulesSettingsView(
                    store: emailRules,
                    accounts: model.statuses,
                    moveDestinations: swipeMoveDestinations
                )
            }
        }
    }

    private func sectionPane<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader(title: title, subtitle: subtitle)
            Rectangle()
                .fill(theme.line.color)
                .frame(height: Hairline.thickness(displayScale))
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.paper.color)
    }

    /// Os destinos são construídos a partir das pastas reais já sincronizadas.
    /// Gmail recebe somente marcadores pessoais e remove INBOX; em IMAP a
    /// pessoa pode escolher qualquer pasta fora da entrada. Não há inferência
    /// por nome, nem uma lista de provedores fechada.
    private var swipeMoveDestinations: [SwipeMoveDestination] {
        guard let mailStore else { return [] }
        var destinations: [SwipeMoveDestination] = []
        for account in mailStore.accounts {
            let folders = mailStore.folders(of: account.id)
            switch account.provider {
            case .gmail:
                guard let inbox = folders.first(where: { $0.role == .inbox }) else { continue }
                destinations += folders.compactMap { folder in
                    guard folder.role == .other else { return nil }
                    return SwipeMoveDestination(
                        gmailLabel: folder,
                        removing: inbox,
                        accountLabel: account.address
                    )
                }
            case .imap, .microsoft:
                destinations += folders
                    .filter { $0.role != .inbox }
                    .map { folder in
                        SwipeMoveDestination(imapFolder: folder, accountLabel: account.address)
                    }
            }
        }
        return destinations.sorted {
            if $0.accountLabel != $1.accountLabel {
                return ($0.accountLabel ?? $0.accountID)
                    .localizedCaseInsensitiveCompare($1.accountLabel ?? $1.accountID) == .orderedAscending
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var accountsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text("CONTAS CONECTADAS")
                        .capsLabel(size: 8.5)
                    Text("\(model.statuses.count)")
                        .font(theme.mono.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.accent.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(theme.accentSoft.color, in: Capsule())
                }
                Text("Escolha uma conta para ver o estado e as ações disponíveis.")
                    .font(theme.sans.font(size: 10))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.statuses) { status in accountButton(status) }
                }
                .padding(.horizontal, 8)
            }

            Rectangle()
                .fill(theme.line.color)
                .frame(height: Hairline.thickness(displayScale))

            HStack(spacing: 7) {
                Button {
                    addingAccount = true
                    selectedAccountID = nil
                } label: {
                    Label("Adicionar", systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .settingsSidebarAction(primary: true)
                .help("Adicionar conta")

                Button {
                    if let id = selectedAccountID { removendo = id }
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 30, height: 30)
                }
                .disabled(selectedAccountID == nil || addingAccount)
                .help("Remover a conta selecionada")
                .settingsSidebarAction(primary: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(theme.surface2.color)
    }

    private func accountButton(_ status: AccountStatus) -> some View {
        let selected = !addingAccount && selectedAccountID == status.accountID
        return Button {
            addingAccount = false
            selectedAccountID = status.accountID
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? theme.accent.color : theme.surface3.color)
                    Text(String(status.hostMark.prefix(1)).uppercased())
                        .font(theme.sans.font(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? theme.onAccent.color : theme.ink2.color)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(status.hostMark.uppercased())
                        .font(theme.sans.font(size: 12, weight: .semibold))
                        .foregroundStyle(theme.ink.color)
                    Text(status.address)
                        .font(theme.sans.font(size: 10.5))
                        .foregroundStyle(theme.ink3.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 7, height: 7)
                    .help(AccountsCopy.status(status, now: Date(), calendar: .current))
            }
            .padding(.horizontal, 9)
            .frame(height: 52)
            .background(
                selected ? theme.surface3.color : Color.clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 9)
    }

    @ViewBuilder
    private var accountsDetail: some View {
        if addingAccount || selectedStatus == nil {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(
                    title: "Adicionar conta",
                    subtitle: "Google, Gmail por senha de app ou qualquer servidor IMAP"
                )
                Rectangle()
                    .fill(theme.line.color)
                    .frame(height: Hairline.thickness(displayScale))
                ScrollView { AddAccountForm(model: model) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let status = selectedStatus {
            accountDetail(status)
        }
    }

    private var selectedStatus: AccountStatus? {
        model.statuses.first { $0.accountID == selectedAccountID }
    }

    private func accountDetail(_ status: AccountStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader(title: status.address, subtitle: status.hostMark.uppercased())
            Rectangle()
                .fill(theme.line.color)
                .frame(height: Hairline.thickness(displayScale))

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    accountState(status)
                    informationCard(status)

                    HStack(spacing: 10) {
                        ForEach(AccountsCopy.actions(for: status).filter { $0 != .remove }) { action in
                            Button(action.label) { execute(action, on: status.accountID) }
                                .buttonStyle(.plain)
                                .font(theme.sans.font(size: 12, weight: .semibold))
                                .foregroundStyle(theme.accent.color)
                                .padding(.horizontal, 13)
                                .frame(height: 30)
                                .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
                                }
                                .help(action.help)
                        }
                        Spacer(minLength: 0)
                    }

                    Rectangle()
                        .fill(theme.line.color)
                        .frame(height: Hairline.thickness(displayScale))

                    Button("Remover conta…") { removendo = status.accountID }
                        .buttonStyle(.plain)
                        .font(theme.sans.font(size: 12, weight: .medium))
                        .foregroundStyle(theme.danger.color)
                        .help("Apagar esta conta, as mensagens baixadas e a senha guardada")
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.paper.color)
    }

    private func detailHeader(title: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 13) {
            RoundedRectangle(cornerRadius: 4)
                .fill(theme.accent.color)
                .frame(width: 4, height: 31)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(theme.sans.font(size: 18, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(theme.sans.font(size: 11))
                    .foregroundStyle(theme.ink3.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 25)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(theme.surface.color)
    }

    private func accountState(_ status: AccountStatus) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 10, height: 10)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(AccountsCopy.isFailing(status) ? "A conta precisa de atenção" : "Conta conectada")
                    .font(theme.sans.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                Text(AccountsCopy.status(status, now: Date(), calendar: .current))
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(AccountsCopy.isFailing(status) ? theme.danger.color : theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress = status.progress, progress.total > 0 {
                    ProgressView(value: progress.fraction)
                        .tint(theme.accent.color)
                        .frame(maxWidth: 300)
                }
            }
        }
    }

    private func informationCard(_ status: AccountStatus) -> some View {
        VStack(spacing: 0) {
            informationRow("Endereço", value: status.address)
            cardDivider
            informationRow("Servidor", value: status.hostMark)
            cardDivider
            informationRow("Mensagens locais", value: "\(status.messageCount)")
            cardDivider
            informationRow(
                "Fila de saída",
                value: status.pendingOperations == 0
                    ? "Nenhuma operação pendente"
                    : "\(status.pendingOperations) aguardando"
            )
        }
        .background(theme.surface2.color, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
    }

    private func informationRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(theme.sans.font(size: 11.5, weight: .medium))
                .foregroundStyle(theme.ink3.color)
                .frame(width: 118, alignment: .trailing)
            Text(value)
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink.color)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 42)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(theme.line.color)
            .frame(height: Hairline.thickness(displayScale))
            .padding(.leading, 148)
    }

    private func statusColor(_ status: AccountStatus) -> Color {
        if AccountsCopy.isFailing(status) { return theme.danger.color }
        if status.state == .carregando { return theme.accent.color }
        return theme.success.color
    }

    private func execute(_ action: AccountRowAction, on accountID: String) {
        switch action {
        case .reconnect: Task { await model.loadInitial(accountID) }
        case .retry: Task { await model.loadInitial(accountID) }
        case .retryQueue: Task { await model.retryQueue(accountID) }
        case .openRoteiro: AccountsDocs.open(AccountsDocs.oauthGoogle)
        case .remove: removendo = accountID
        }
    }
}

private extension View {
    func settingsSidebarAction(primary: Bool) -> some View {
        modifier(SettingsSidebarActionStyle(primary: primary))
    }
}

private struct SettingsSidebarActionStyle: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let primary: Bool

    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .font(theme.sans.font(size: 10.5, weight: .semibold))
            .foregroundStyle(primary ? theme.onAccent.color : theme.ink3.color)
            .background(primary ? theme.accent.color : theme.surface.color, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(primary ? theme.accent.color : theme.line2.color, lineWidth: Hairline.thickness(displayScale))
            }
            .focusRing(cornerRadius: 8)
    }
}

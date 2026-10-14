import SwiftUI
import UNICore
import UNIDesign

/// A coluna de 216pt ao lado do trilho: título da tela, recolher, busca, a
/// ação principal, o conteúdo da tela e, no pé, a atualização pronta.
///
/// Ela é a metade de dentro do painel da lateral — o trilho é a de fora, e as
/// duas dividem o mesmo vidro. Recolher esconde **esta** coluna e deixa o
/// trilho, que é o que o botão `sidebar.left` da barra antiga fazia.
///
/// Protótipo: `Sidebar.dc.html`, o `<div>` do `sc-if value="{{open}}"`.
struct ContextSidebar: View {
    static let width: CGFloat = PaneLayout.contextSidebarWidth

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let store: MailStore
    let workspace: Workspace
    @Binding var query: String
    @Binding var searchEverywhere: Bool
    @Binding var dashboardFilter: DayPlan.Filter
    let intelligencePresentation: IntelligencePresentation
    let analysisPause: AnalysisPauseState?
    let syncStatus: MailboxChromeStatus
    let statusPhrase: String
    let onReloadMailbox: (() -> Void)?
    let onSearchFocusChange: (Bool) -> Void
    let onCollapse: () -> Void
    let onCompose: () -> Void
    let onNewAppointment: () -> Void
    let onOpenAssistant: () -> Void
    let onOpenSettings: () -> Void
    let updates: UpdateController?
    /// Conteúdo da aba Agenda: a mesma `CalendarSidebar` da tela, que precisa
    /// do dia escolhido e do seletor dela. Vem de fora porque esse estado é da
    /// `CalendarScreen`, não desta coluna.
    let calendarContent: AnyView?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            GlassSearchField(
                query: $query,
                searchEverywhere: $searchEverywhere,
                accountCount: store.accounts.count,
                syncStatus: syncStatus,
                statusPhrase: statusPhrase,
                onReload: onReloadMailbox,
                onFocusChange: onSearchFocusChange
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            if let action = primaryAction {
                primaryButton(action)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let analysisPause {
                AnalysisPausedBand(reason: analysisPause.reason, onRetry: analysisPause.retry)
            }

            if let updates, updates.showsReadyButton {
                UpdateReadyRow(controller: updates)
                    .padding(10)
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Cabeçalho

    private var header: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(theme.sans.font(size: 17, weight: .bold))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onCollapse) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(theme.ink3.color)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: [.control, .command])
            .focusRing(cornerRadius: theme.radiusSmall)
            .help(L10n.tr("Recolher a barra lateral"))
            .accessibilityLabel(L10n.tr("Recolher a barra lateral"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private var title: String {
        switch workspace {
        case .dashboard: Workspace.dashboard.label
        case .mail: L10n.tr("Caixa")
        case .calendar: L10n.tr("Agenda")
        }
    }

    // MARK: - Ação principal

    private var primaryAction: (label: String, symbol: String, action: () -> Void)? {
        switch workspace {
        case .mail: (L10n.tr("Escrever"), "square.and.pencil", onCompose)
        case .calendar: (L10n.tr("Novo compromisso"), "plus", onNewAppointment)
        // O Painel não cria nada: ele é a leitura do dia.
        case .dashboard: nil
        }
    }

    private func primaryButton(
        _ action: (label: String, symbol: String, action: () -> Void)
    ) -> some View {
        Button(action: action.action) {
            HStack(spacing: 8) {
                Image(systemName: action.symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(action.label)
                    .font(theme.sans.font(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(theme.onAccent.color)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(theme.accent.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall, tint: \.onAccent)
        .help(
            workspace == .mail
                ? L10n.tr("Nova mensagem (⌘N)")
                : L10n.tr("Novo compromisso")
        )
        .accessibilityLabel(action.label)
    }

    // MARK: - Conteúdo por tela

    @ViewBuilder
    private var content: some View {
        switch workspace {
        case .mail:
            FolderSidebar(
                store: store,
                width: Self.width,
                intelligencePresentation: intelligencePresentation,
                onOpenAssistant: onOpenAssistant,
                onOpenSettings: onOpenSettings,
                chrome: .embedded
            )
        case .calendar:
            if let calendarContent {
                calendarContent
            }
        case .dashboard:
            businessFilter
        }
    }

    /// O filtro de negócios do Painel, de pé.
    ///
    /// É o **mesmo** `DayPlan.Filter.accounts` do segmentado que o
    /// `PainelDoDia` desenha no cabeçalho dele — um clique aqui recorta o
    /// painel, e não há um segundo estado de filtro. O que esta lista não
    /// mostra são as contagens por conta: elas saem de `PainelDoDiaModelo`,
    /// que é montado dentro da tela, e trazê-lo até aqui ia custar mais do que
    /// vale nesta fase.
    private var businessFilter: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tr("Negócios"))
                    .capsLabel(size: 9.5)
                    .padding(EdgeInsets(top: 4, leading: 14, bottom: 7, trailing: 14))

                filterRow(
                    label: L10n.tr("Tudo"), tint: theme.ink3.color,
                    active: dashboardFilter.accounts.isEmpty
                ) { dashboardFilter.accounts = [] }

                ForEach(store.accounts) { account in
                    let tint = TokenColor(css: account.tint(isDark: theme.isDark)) ?? theme.ink4
                    filterRow(
                        label: account.shortName, tint: tint.color,
                        active: dashboardFilter.accounts.contains(account.id)
                    ) {
                        if dashboardFilter.accounts.contains(account.id) {
                            dashboardFilter.accounts.remove(account.id)
                        } else {
                            dashboardFilter.accounts.insert(account.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func filterRow(
        label: String, tint: Color, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(theme.sans.font(size: 12.5, weight: active ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle((active ? theme.ink : theme.ink2).color)
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .background {
                RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                    .fill(active ? theme.accentSoft.color : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// O campo de busca da coluna de contexto: "Buscar em tudo ⌘K", a barra fina
/// de estado da caixa por baixo, e o recarregar ao lado.
///
/// É o `searchCluster` da `WindowChrome` mudado de casa. O atalho, o selo
/// "Tudo", o Esc que cancela e a identidade do campo para o respondedor
/// continuam sendo os mesmos — se fossem outros, ⌘K passaria a cair num campo
/// e o Esc noutro.
struct GlassSearchField: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    @Binding var query: String
    @Binding var searchEverywhere: Bool
    let accountCount: Int
    let syncStatus: MailboxChromeStatus
    let statusPhrase: String
    let onReload: (() -> Void)?
    let onFocusChange: (Bool) -> Void

    @FocusState private var focused: Bool
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.ink3.color)
                TextField(L10n.tr("Buscar em tudo"), text: $query)
                    .textFieldStyle(.plain)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink.color)
                    .focused($focused)
                    .accessibilityIdentifier(WindowChrome.searchFieldID)
                    .onKeyPress(.escape) {
                        cancel()
                        return .handled
                    }
                    .onExitCommand(perform: cancel)
                    .onChange(of: focused) { _, now in onFocusChange(now) }
                if WindowChrome.showsEverywhereFlag(query) {
                    everywhereChip
                } else {
                    Text("⌘K")
                        .font(theme.mono.font(size: 10))
                        .foregroundStyle(theme.ink4.color)
                }
                if let onReload {
                    reloadButton(onReload)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(theme.surface3.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                    .strokeBorder(
                        focused ? theme.focus.color : theme.line.color,
                        lineWidth: Hairline.thickness(displayScale)
                    )
            }

            statusBar
        }
        .background(searchShortcut)
    }

    private func cancel() {
        query = ""
        focused = false
    }

    /// Ver `WindowChrome.searchShortcut`: um `Button` escondido é o que entra
    /// no `performKeyEquivalent` da janela, que é por onde um ⌘ chega.
    private var searchShortcut: some View {
        Button(L10n.tr("Buscar")) { focused = true }
            .keyboardShortcut("k", modifiers: .command)
            .hidden()
            .accessibilityHidden(true)
    }

    private var everywhereChip: some View {
        Button { searchEverywhere.toggle() } label: {
            Text(WindowChrome.searchEverywhereLabel)
                .font(theme.sans.font(size: 10, weight: searchEverywhere ? .semibold : .medium))
                .foregroundStyle((searchEverywhere ? theme.accentInk : theme.ink4).color)
                .padding(.horizontal, searchEverywhere ? 6 : 0)
                .frame(height: 18)
                .background(searchEverywhere ? theme.accentSoft.color : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(
            searchEverywhere
                ? WindowChrome.searchEverywhereHelpOn : WindowChrome.searchEverywhereHelpOff
        )
        .accessibilityLabel(WindowChrome.searchEverywhereLabel)
        .accessibilityValue(searchEverywhere ? L10n.tr("ligado") : L10n.tr("desligado"))
    }

    private func reloadButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle((syncStatus.canReload ? theme.ink2 : theme.ink4).color)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .symbolEffect(.rotate, options: .repeating, isActive: syncStatus.isBusy)
        }
        .buttonStyle(.plain)
        .disabled(!syncStatus.canReload)
        .focusRing(cornerRadius: theme.radiusSmall)
        .help(statusPhrase)
        .accessibilityLabel(L10n.tr("Atualizar a caixa"))
        .accessibilityIdentifier("mailbox-reload")
        .accessibilityValue(statusPhrase)
    }

    /// A mesma barra fina da `WindowChrome`, com a mesma regra: parada ela é
    /// cinza, e cor nesta barra quer dizer trabalho acontecendo agora.
    private var statusBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.line.color.opacity(0.55))
                switch syncStatus {
                case .empty, .ready:
                    EmptyView()
                case let .loading(fraction):
                    if let fraction {
                        Capsule()
                            .fill(theme.activity.color)
                            .frame(width: max(6, geo.size.width * fraction))
                    } else {
                        Capsule()
                            .fill(theme.activity.color)
                            .frame(width: max(8, geo.size.width * WindowChrome.cursorFraction))
                            .offset(x: pulse ? geo.size.width : 0)
                            .onAppear {
                                pulse = false
                                withAnimation(
                                    .linear(duration: 1.1).repeatForever(autoreverses: false)
                                ) { pulse = true }
                            }
                    }
                case .failed:
                    Capsule().fill(theme.danger.color)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("Estado da caixa"))
        .accessibilityValue(statusPhrase)
        .accessibilityIdentifier("mailbox-sync-status")
        .help(statusPhrase)
    }
}

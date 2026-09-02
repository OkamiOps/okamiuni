import AppKit
import SwiftUI
import UNIDesign
import UNICore

public enum Workspace: String, CaseIterable, Sendable {
    case dashboard, mail, calendar

    public var label: String {
        switch self {
        case .dashboard: "Dashboard"
        case .mail: "Caixa"
        case .calendar: "Agenda"
        }
    }

    /// A busca não tem lista nesta aba. Digitar um termo leva de volta à
    /// Caixa, que é quem recorta as mensagens.
    public func switchingToMailIfSearching(_ query: String) -> Workspace {
        let termo = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self == .dashboard, !termo.isEmpty else { return self }
        return .mail
    }
}

/// Os controles da barra, na ordem em que aparecem da esquerda para a direita.
///
/// Isto não é documentação: `WindowChrome.body` percorre `controlOrder` para
/// montar o `HStack`, então mudar a lista muda o que a janela desenha — e o
/// teste que trava a lista trava a barra.
public enum ChromeControl: String, CaseIterable, Sendable {
    case sidebarToggle, tabs, search, agendaToggle, themePicker, compose, accounts
}

public struct WindowChrome: View {
    public static let height: CGFloat = 64

    /// Ordem estrutural: recolhe colado nos semáforos, busca elástica no
    /// centro, abas e utilidades à direita. O lobo da marca fica ao lado
    /// do recolhe, fora desta lista — não é controle.
    public static let controlOrder: [ChromeControl] = [
        .sidebarToggle,
        .search,
        .tabs,
        .agendaToggle,
        .themePicker,
        .accounts,
    ]

    /// O único controle que cede largura. Os outros medem o que precisam; este
    /// come a folga em janela larga e é o primeiro a encolher em janela
    /// estreita.
    public static let flexibleControl: ChromeControl = .search

    /// A linha média da fileira de controles, contada do topo da janela.
    ///
    /// Os semáforos, o recolhe e o lobo da marca ficam na linha nativa de
    /// 22pt. A busca, as abas e a conta ocupam o centro da toolbar de 64pt.
    public static let centerY: CGFloat = height / 2

    /// Item de toolbar compacto, o da fileira colada aos semáforos.
    ///
    /// Finder, Mail e Notes usam o símbolo `sidebar.left` nesta escala: glifo
    /// de 14pt numa hit-target de 24pt. A caixa de 38pt com borda e sombra é o
    /// padrão dos outros botões da barra — colada no semáforo ela fica fora
    /// da plataforma.
    static let sidebarControlSize: CGFloat = 24
    static let sidebarControlSymbolSize: CGFloat = 14
    static let sidebarControlRadius: CGFloat = 5
    /// Topo do recolhe para o centro cair na linha dos semáforos (22), não
    /// na linha média da toolbar (32). O HStack centra tudo em 32; sem este
    /// empurrão o ícone de 24pt fica 10pt abaixo das bolinhas.
    static var sidebarControlTopInset: CGFloat {
        TrafficLightLayout.contentCenterFromTop - sidebarControlSize / 2
    }
    /// Onde terminam os semáforos nativos da janela, medido por acessibilidade
    /// numa janela `.hiddenTitleBar`: fechar em x=8, minimizar em x=31, tela cheia
    /// em x=54, todos com 16pt — o último termina em **x=70**.
    ///
    /// O `HStack` acrescenta seu `spacing` de 14 depois deste vazio, então o
    /// primeiro controle nasce em x=84 — os mesmos 14pt de folga que o protótipo
    /// deixa entre seus semáforos desenhados e o botão da barra lateral.
    ///
    /// Estava 78 e produzia 22pt de vão, largo demais ao lado de qualquer app
    /// nativo. Não aumente sem medir de novo.
    public static let trafficLightInset: CGFloat = 70

    /// Raio dos cantos das abas Dashboard/Caixa/Agenda. Segue o token do tema: o Okami
    /// pede 2pt (cantos vivos do design system). Antes era `max(r3, 17)` e
    /// todo tema virava pílula — o Okami nunca chegava a parecer o site.
    public static func tabCornerRadius(for theme: Theme) -> CGFloat {
        max(theme.radiusLarge, 0)
    }

    /// Campo de busca e o trilho das abas: cápsula nos temas redondos, o
    /// raio do token nos temas vivos (Okami, Brutal).
    public static func chromePillRadius(for theme: Theme) -> CGFloat {
        theme.radiusLarge <= 4 ? theme.radiusLarge : 20
    }

    /// O protótipo diz "Buscar nas 4 caixas…" porque tinha quatro contas.
    /// Como a quantidade é do usuário, o texto concorda com ela.
    public static func searchPlaceholder(_ accountCount: Int) -> String {
        switch accountCount {
        case 0: "Buscar"
        case 1: "Buscar na caixa…"
        default: "Buscar nas \(accountCount) caixas…"
        }
    }

    /// O selo aparece depois da primeira letra. Sem termo, a busca é da caixa
    /// e o ⌘K continua no canto.
    public static func showsEverywhereFlag(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static let searchEverywhereLabel = "Tudo"
    public static let searchEverywhereHelpOff =
        "Busca nesta caixa. Clique para procurar em todas as pastas."
    public static let searchEverywhereHelpOn =
        "Buscando em todas as pastas. Clique para voltar a esta caixa."

    /// Identidade do campo para o Esc achar a busca no respondedor. O editor
    /// de campo do AppKit é um `NSTextView` filho; a marca fica neste id.
    public static let searchFieldID = BareKeyFocus.searchFieldID

    /// A largura do campo de busca no protótipo. Aqui é um teto, não uma
    /// largura: em 1440 sobra espaço e o campo o alcança, ficando idêntico.
    public static let searchIdealWidth: CGFloat = 720

    /// Abaixo disto o campo deixa de ser usável — o placeholder trunca e o
    /// "⌘K" encosta no cursor. A partir daqui quem cede é a folga do `HStack`.
    public static let searchMinimumWidth: CGFloat = 180

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Binding var workspace: Workspace
    @Binding var query: String
    @Binding var searchEverywhere: Bool
    let accountCount: Int
    let onToggleSidebar: () -> Void
    let onToggleAgenda: () -> Void
    /// Abre a janela 06 (Nova mensagem). O mesmo caminho do ⌘N.
    let onCompose: () -> Void
    let accountMonogram: String
    let onOpenAccounts: () -> Void
    let syncStatus: MailboxChromeStatus
    /// "há 4 min" — o instante da última sync, fora do enum de estado.
    let syncCaption: String?
    /// O que está acontecendo **agora**, quando é mais do que sincronizar:
    /// "Analisando 23 de 312", "Perguntando ao Codex · ChatGPT". Vem pronto
    /// de `ChromeWorkload`, que soma os trabalhos fora da `View`; `nil` em
    /// repouso, e aí vale a legenda de sempre.
    let statusDetail: String?
    let onReloadMailbox: (() -> Void)?
    /// A caixa precisa saber se a busca está focada: o Esc cancela o campo
    /// mesmo quando o monitor da lista vê só o editor de campo do AppKit.
    let onSearchFocusChange: (Bool) -> Void
    @State private var sidebarHovering = false
    @State private var agendaHovering = false
    @State private var reloadHovering = false
    @State private var statusPulse = false
    /// O destino do ⌘K. Ver `searchShortcut`.
    @FocusState private var searchFocused: Bool
    /// Onde cada controle da barra ficou. Só a captura do duplo clique lê isto
    /// — ver `TitleBarDoubleClick`.
    @State private var controlFrames: [CGRect] = []

    /// O espaço em que as molduras dos controles são medidas: a própria barra,
    /// com origem no canto superior esquerdo dela.
    static let barSpace = "uni.chrome.bar"

    public init(
        workspace: Binding<Workspace>,
        query: Binding<String>,
        searchEverywhere: Binding<Bool> = .constant(false),
        accountCount: Int,
        onToggleSidebar: @escaping () -> Void,
        onToggleAgenda: @escaping () -> Void,
        onCompose: @escaping () -> Void = {},
        accountMonogram: String = "UNI",
        onOpenAccounts: @escaping () -> Void = {},
        syncStatus: MailboxChromeStatus = .empty,
        syncCaption: String? = nil,
        statusDetail: String? = nil,
        onReloadMailbox: (() -> Void)? = nil,
        onSearchFocusChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self._workspace = workspace
        self._query = query
        self._searchEverywhere = searchEverywhere
        self.accountCount = accountCount
        self.onToggleSidebar = onToggleSidebar
        self.onToggleAgenda = onToggleAgenda
        self.onCompose = onCompose
        self.accountMonogram = accountMonogram
        self.onOpenAccounts = onOpenAccounts
        self.syncStatus = syncStatus
        self.syncCaption = syncCaption
        self.statusDetail = statusDetail
        self.onReloadMailbox = onReloadMailbox
        self.onSearchFocusChange = onSearchFocusChange
    }

    public var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: Self.trafficLightInset - 12, height: 1)

            ForEach(Self.controlOrder, id: \.self) { control in
                view(for: control)
                if control == .sidebarToggle { brandMark }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        // O referencial em que as molduras dos controles são medidas. Tem de
        // ficar aqui, sobre a barra já com a altura final: é este retângulo que
        // a captura do duplo clique cobre, e os dois precisam ter a mesma
        // origem para as molduras significarem a mesma coisa dos dois lados.
        .coordinateSpace(.named(Self.barSpace))
        .onPreferenceChange(ChromeControlFrames.self) { frames in
            MainActor.assumeIsolated { controlFrames = frames }
        }
        .background(theme.surface2.color)
        // ⌘K. Ver `searchShortcut` — o campo escreve o atalho dentro de si
        // desde a Task S e ninguém escutava.
        .background(searchShortcut)
        // Numa janela `.hiddenTitleBar` a barra nativa fica atrás do nosso
        // conteúdo, então o duplo clique não chegava nela e a janela ignorava o
        // ajuste do sistema. Ver `TitleBarDoubleClick`.
        .titleBarDoubleClick(controls: controlFrames, barHeight: Self.height)
        .hairline(theme.line, edges: .bottom)
        // Sobe os semáforos nativos para a linha média da barra. Tamanho zero e
        // sem hit test: não participa do layout nem come clique.
        .trafficLightsOnTheLine(barHeight: Self.height)
    }

    /// Cada controle publica a moldura **do que ele desenha**, e é por isso que
    /// `.chromeControlFrame` entra aqui dentro e não em volta do `ForEach`: a
    /// busca vem embrulhada num `frame(maxWidth: .infinity)` que come toda a
    /// folga da barra, e medir o embrulho apagaria a área vazia inteira — a
    /// captura do duplo clique não teria onde cair.
    @ViewBuilder
    private func view(for control: ChromeControl) -> some View {
        switch control {
        case .sidebarToggle: sidebarToggle
        case .tabs: workspaceTabs.chromeControlFrame(in: Self.barSpace)
        case .search:
            searchCluster
                .chromeControlFrame(in: Self.barSpace)
                // Protótipo: `flex: 1; justify-content: center` em volta do
                // campo. O campo em si tem uma faixa, não uma largura: em 1440
                // ele bate no teto de 720 e ocupa a folga do novo shell; numa
                // janela estreita ele cede antes de espremer as abas.
                .frame(maxWidth: .infinity)
        case .agendaToggle: agendaToggle.chromeControlFrame(in: Self.barSpace)
        case .themePicker: ThemePicker().chromeControlFrame(in: Self.barSpace)
        case .compose: composeButton.chromeControlFrame(in: Self.barSpace)
        case .accounts: accountsButton.chromeControlFrame(in: Self.barSpace)
        }
    }

    /// Protótipo, linha 359: `height: 27px; padding: 0 12px; border-radius:
    /// var(--r2); background: var(--accent); color: var(--on-accent);
    /// font-size: 12.5px; font-weight: 590`, com o "+" de 14px e `gap: 6px`.
    private var composeButton: some View {
        Button(action: onCompose) {
            HStack(spacing: 6) {
                Text("+")
                    .font(theme.sans.font(size: 14))
                Text("Escrever")
                    .font(theme.sans.font(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(theme.onAccent.color)
            .frame(height: 27)
            .padding(.horizontal, 12)
            .background(theme.accent.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall, tint: \.onAccent)
        .accessibilityLabel("Escrever uma nova mensagem")
        .help("Nova mensagem (⌘N)")
    }

    private var accountsButton: some View {
        Button(action: onOpenAccounts) {
            Text(accountMonogram)
                .font(theme.sans.font(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .frame(width: 38, height: 38)
                .background(theme.surface3.color)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .focusRing(in: Circle())
        .help("Contas e providers")
        .accessibilityLabel("Abrir contas e providers")
    }

    private var sidebarToggle: some View {
        paneToggle(
            systemName: "sidebar.left",
            hovering: $sidebarHovering,
            action: onToggleSidebar,
            accessibilityLabel: "Mostrar ou esconder a barra lateral",
            help: "Mostrar ou esconder a barra lateral"
        )
        .chromeControlFrame(in: Self.barSpace)
        .padding(.top, Self.sidebarControlTopInset)
        .frame(height: Self.height, alignment: .top)
    }

    /// Símbolo só, 22pt, na linha das bolinhas. Não entra em `controlOrder`:
    /// não é botão, e o duplo clique por cima dele continua sendo da janela.
    private var brandMark: some View {
        BrandLockup()
            .padding(.top, TrafficLightLayout.contentCenterFromTop - BrandLockup.titlebarSize / 2)
            .frame(height: Self.height, alignment: .top)
    }

    /// O protótipo não tem este controle: nele a agenda está sempre visível
    /// porque a página só existe em 1440. Aqui ela sai sozinha abaixo de 1280,
    /// e sem um botão o usuário perderia a função sem meio de recuperá-la.
    /// É o mesmo item nativo do recolhe da esquerda, espelhado (`sidebar.right`)
    /// porque a trilha vive à direita.
    private var agendaToggle: some View {
        paneToggle(
            systemName: "sidebar.right",
            hovering: $agendaHovering,
            action: onToggleAgenda,
            accessibilityLabel: "Mostrar ou esconder a trilha da agenda",
            help: "Mostrar ou esconder a trilha da agenda"
        )
    }

    /// Recolhe de painel no tamanho de um item de toolbar do macOS: o símbolo
    /// `sidebar.left` / `sidebar.right`, glifo de 14pt, hit-target de 24pt,
    /// realce só no hover. Sem caixa de 38pt, sem borda, sem sombra — é o que
    /// Finder, Mail, Notes e o Synara põem ao lado do semáforo.
    private func paneToggle(
        systemName: String,
        hovering: Binding<Bool>,
        action: @escaping () -> Void,
        accessibilityLabel: String,
        help: String
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: Self.sidebarControlSymbolSize, weight: .regular))
                .foregroundStyle((hovering.wrappedValue ? theme.ink : theme.ink2).color)
                .frame(width: Self.sidebarControlSize, height: Self.sidebarControlSize)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                        .fill(hovering.wrappedValue ? theme.line2.color : Color.clear)
                }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .onHover { hovering.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering.wrappedValue)
        .accessibilityLabel(accessibilityLabel)
        .help(help)
    }

    private var workspaceTabs: some View {
        let radius = Self.tabCornerRadius(for: theme)
        let sharp = theme.radiusLarge <= 4
        return HStack(spacing: 2) {
            ForEach(Workspace.allCases, id: \.self) { tab in
                let active = tab == workspace
                Button { workspace = tab } label: {
                    Text(tab.label)
                        .font(theme.sans.font(size: 13, weight: sharp && active ? .semibold : .medium))
                        .foregroundStyle((active ? theme.ink : theme.ink3).color)
                        .padding(.horizontal, 13)
                        .frame(height: 34)
                        .background {
                            if active, !sharp {
                                RoundedRectangle(cornerRadius: radius)
                                    .fill(theme.surface.color)
                                    // Sombra literal do protótipo (`0 1px 2px rgba(0,0,0,0.08)`), não um token do tema.
                                    // SwiftUI usa metade do blur do CSS — mesma conversão de ShadowToken.radius — então blur 2px vira radius 1.
                                    .shadow(color: .black.opacity(0.08), radius: 1, x: 0, y: 1)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if active, sharp {
                                Rectangle()
                                    .fill(theme.accent.color)
                                    .frame(height: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: radius)
            }
        }
        .padding(3)
        .background(theme.surface3.color)
        .clipShape(RoundedRectangle(cornerRadius: Self.chromePillRadius(for: theme) == 20 ? 20 : radius + 3, style: .continuous))
    }

    /// O ⌘K que o campo de busca promete por escrito.
    ///
    /// O campo desenha "⌘K" no canto direito desde a Task S. Até a Task AQ
    /// **nada no app escutava essa tecla**: era um botão mudo em forma de
    /// atalho, e o ensaio no app real (`--ensaiar-teclado`) mediu exatamente
    /// isso — o primeiro respondedor não mudava.
    ///
    /// Um `Button` escondido, e não `onKeyPress`: `keyboardShortcut` é o que
    /// entra no `performKeyEquivalent` da janela, que é por onde um atalho com
    /// ⌘ chega. `.hidden()` tira o botão do desenho sem o tirar da hierarquia —
    /// e como ele vem por `background`, não ocupa lugar no layout da barra.
    private var searchShortcut: some View {
        Button("Buscar") { searchFocused = true }
            .keyboardShortcut("k", modifiers: .command)
            .hidden()
            .accessibilityHidden(true)
    }

    /// Campo, barrinha de estado e o recarregar. O recarregar fica **ao lado**
    /// da busca; a barrinha, **abaixo** — é o recorte que a pessoa pediu para
    /// ver se a caixa ainda está no ar sem esperar o ciclo automático.
    private var searchCluster: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(spacing: 4) {
                searchField
                mailboxStatusBar
            }
            reloadButton
        }
        .frame(minWidth: Self.searchMinimumWidth, maxWidth: Self.searchIdealWidth)
    }

    /// Esc na busca: apaga o termo e devolve o foco. Uma tecla só cancela a
    /// ação — não deixa o campo vazio ainda focado pedindo um segundo Esc.
    private func cancelSearch() {
        query = ""
        searchFocused = false
    }

    /// Selo no canto do campo, no lugar do ⌘K. Desligado pesa como o atalho —
    /// só a palavra, sem caixa. Ligado vira o acento. A barra não ganha um
    /// segundo controle permanente.
    private var searchEverywhereChip: some View {
        let on = searchEverywhere
        let radius = Self.chromePillRadius(for: theme)
        return Button {
            searchEverywhere.toggle()
        } label: {
            Text(Self.searchEverywhereLabel)
                .font(theme.sans.font(size: 11, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? theme.accentInk.color : theme.ink4.color)
                .padding(.horizontal, on ? 8 : 0)
                .frame(height: 20)
                .background(on ? theme.accentSoft.color : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    if on {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(
                                theme.accent.color,
                                lineWidth: Hairline.thickness(displayScale)
                            )
                    }
                }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(on ? Self.searchEverywhereHelpOn : Self.searchEverywhereHelpOff)
        .accessibilityLabel(Self.searchEverywhereLabel)
        .accessibilityValue(on ? "ligado" : "desligado")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(Self.searchEverywhereHelpOff)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Circle()
                .strokeBorder(theme.ink4.color, lineWidth: 1.5)
                .frame(width: 10, height: 10)
            TextField(Self.searchPlaceholder(accountCount), text: $query)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.ink.color)
                .focused($searchFocused)
                .accessibilityIdentifier(Self.searchFieldID)
                .onKeyPress(.escape) {
                    cancelSearch()
                    return .handled
                }
                .onExitCommand(perform: cancelSearch)
                .onChange(of: searchFocused) { _, focused in
                    onSearchFocusChange(focused)
                }
            if Self.showsEverywhereFlag(query) {
                searchEverywhereChip
            } else {
                Text("⌘K")
                    .font(theme.mono.font(size: 10))
                    .foregroundStyle(theme.ink4.color)
            }
        }
        .padding(.horizontal, 16)
        // Era `.frame(width: 400)`. Uma largura cravada aqui não encolhe: numa
        // janela estreita ela empurra as abas e o seletor de tema para fora da
        // barra. Como faixa, o campo é o primeiro a ceder — e em 1440 sobra
        // folga de sobra, então ele bate nos 400 do protótipo e não se move.
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: Self.chromePillRadius(for: theme), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.chromePillRadius(for: theme), style: .continuous)
                .strokeBorder(
                    searchFocused ? theme.focus.color : theme.line.color,
                    lineWidth: Hairline.thickness(displayScale)
                )
        }
    }

    /// A frase que a barra fina, o botão de recarregar e o VoiceOver dizem.
    /// O trabalho em curso ganha da legenda: "Atualizada há 4 min" enquanto a
    /// IA pensa é verdade sobre a caixa e mentira sobre a espera.
    var statusPhrase: String {
        if let statusDetail { return statusDetail }
        if let syncCaption { return "Atualizada \(syncCaption)" }
        return syncStatus.label
    }

    private var reloadHelp: String {
        if let statusDetail { return statusDetail }
        if let syncCaption {
            if onReloadMailbox != nil && syncStatus.canReload {
                return "Atualizada \(syncCaption). Atualizar agora, sem esperar o ciclo automático"
            }
            return "Atualizada \(syncCaption)"
        }
        if onReloadMailbox != nil && syncStatus.canReload {
            return "Atualizar a caixa agora, sem esperar o ciclo automático"
        }
        return syncStatus.label
    }

    private var reloadButton: some View {
        let enabled = onReloadMailbox != nil && syncStatus.canReload
        return Button {
            onReloadMailbox?()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle((enabled ? theme.ink2 : theme.ink4).color)
                .frame(width: 38, height: 38)
                .background(theme.surface.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(
                            reloadHovering && enabled ? theme.accent.color : theme.btnLine.color,
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
                .shadow(theme.btnShadow)
                .symbolEffect(.rotate, options: .repeating, isActive: syncStatus.isBusy)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .focusRing(cornerRadius: theme.radiusSmall)
        .onHover { reloadHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: reloadHovering)
        .help(reloadHelp)
        .accessibilityLabel("Atualizar a caixa")
        .accessibilityHint(reloadHelp)
        .accessibilityIdentifier("mailbox-reload")
        .accessibilityValue(statusPhrase)
    }

    private var mailboxStatusBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.line.color.opacity(0.55))
                statusFill(width: geo.size.width)
            }
        }
        .frame(height: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Estado da caixa")
        .accessibilityValue(statusPhrase)
        .accessibilityIdentifier("mailbox-sync-status")
        .help(statusPhrase)
        .onChange(of: syncStatus.isBusy) { _, busy in
            statusPulse = busy
        }
        .onAppear {
            statusPulse = syncStatus.isBusy
        }
    }

    @ViewBuilder
    private func statusFill(width: CGFloat) -> some View {
        switch syncStatus {
        case .empty:
            EmptyView()
        case .loading(let fraction):
            if let fraction {
                Capsule()
                    .fill(theme.activity.color)
                    .frame(width: max(6, width * fraction))
                    .animation(.easeInOut(duration: 0.2), value: fraction)
            } else {
                Capsule()
                    .fill(theme.activity.color)
                    .frame(width: width)
                    .opacity(statusPulse ? 0.9 : 0.28)
                    .animation(
                        .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                        value: statusPulse
                    )
            }
        case .ready:
            Capsule()
                .fill(theme.accentSoft.color)
                .frame(width: width)
        case .failed:
            Capsule()
                .fill(theme.danger.color)
                .frame(width: width)
        }
    }
}

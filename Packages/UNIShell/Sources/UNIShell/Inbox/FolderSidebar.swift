import SwiftUI
import UNIDesign
import UNICore
import UNISync

/// O que a lateral pode afirmar sobre o assistente neste momento.
/// Deixou de ser `CaseIterable`: os casos carregam o destino, e é ele que
/// impede a barra de prometer processamento local com Grok escolhido.
public enum IntelligencePresentation: Sendable, Hashable {
    case available(AssistantDestination)
    case needsSetup(AssistantDestination, detail: String)
    case needsSignIn(AssistantDestination, provider: AssistantProviderOAuthKind?)
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady

    public init(_ availability: AssistantAvailability) {
        switch availability {
        case let .ready(destination):
            self = .available(destination)
        case let .needsSetup(destination, reason):
            self = .needsSetup(destination, detail: reason)
        case let .needsSignIn(destination, provider):
            self = .needsSignIn(destination, provider: provider)
        case let .appleIntelligence(state):
            switch state {
            case .available: self = .available(.onThisMac)
            case .deviceNotEligible: self = .deviceNotEligible
            case .appleIntelligenceNotEnabled: self = .appleIntelligenceNotEnabled
            case .modelNotReady: self = .modelNotReady
            }
        }
    }

    /// O destino de fábrica: o motor local. Serve de padrão às assinaturas e
    /// aos previews, que não podem inventar um destino remoto.
    public static let onThisMac = IntelligencePresentation.available(.onThisMac)

    /// O rótulo da ação fica estável; o estado explica se ela pode ser usada.
    /// Mudar o texto do botão conforme o motor oscila esconderia justamente a
    /// porta que a pessoa procura para entender o que está acontecendo.
    public var actionTitle: String { "Perguntar ao ambiente" }

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var destination: AssistantDestination? {
        switch self {
        case let .available(destination): destination
        case let .needsSetup(destination, _): destination
        case let .needsSignIn(destination, _): destination
        default: nil
        }
    }

    public var title: String {
        switch self {
        case let .available(destination): destination.label
        case .needsSetup: "Configure a IA"
        case .needsSignIn: "Entre na assinatura"
        case .deviceNotEligible: "Apple Intelligence indisponível"
        case .appleIntelligenceNotEnabled: "Ative a Apple Intelligence"
        case .modelNotReady: "Modelo ainda não está pronto"
        }
    }

    /// A frase que decide se o app pode prometer privacidade. Ela vem do
    /// destino, nunca de um texto fixo.
    public var detail: String {
        switch self {
        case let .available(destination):
            "Pergunte sobre suas caixas, emails e agenda. \(destination.detail)"
        case let .needsSetup(_, detail): detail
        case let .needsSignIn(destination, _):
            "Entre na assinatura \(destination.label) para usar a IA."
        case .deviceNotEligible:
            "Este Mac não é compatível com Apple Intelligence. Seus emails continuam locais."
        case .appleIntelligenceNotEnabled:
            "Ative-a nos Ajustes do Sistema para gerar resumos e identificar compromissos."
        case .modelNotReady:
            "A Apple Intelligence ainda está sendo preparada."
        }
    }

    /// O glifo também precisa dizer a verdade sobre a origem. Mostrar o selo
    /// da Apple depois que a pessoa escolheu Codex, Grok, LiteLLM ou um CLI
    /// fazia o provedor remoto parecer um modelo local.
    public var symbol: String {
        guard let destination else { return "apple.intelligence" }
        return destination.isLocal ? "apple.intelligence" : "sparkles"
    }

    /// Copy curta do rodapé. Não pode prometer processamento local quando a
    /// pessoa escolheu OAuth, LiteLLM ou um CLI.
    public var scopeLabel: String {
        guard let destination else { return "Todo o OkamiUNI" }
        return "Todo o OkamiUNI · \(destination.label)"
    }

    public var actionHelp: String {
        isAvailable
            ? "Abre o assistente global para suas caixas, emails e agenda."
            : detail
    }
}

struct IntelligenceFooter: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let presentation: IntelligencePresentation
    let onOpenAssistant: () -> Void
    /// A saída para quem não pode perguntar ainda. Um botão desabilitado sem
    /// caminho para consertar o estado é um beco: aqui ele vem acompanhado.
    var onOpenSettings: () -> Void = {}
    /// A trilha de 72pt não cabe o cartão com duas linhas. Aí vira só o
    /// ícone e "IA", o mesmo desenho da `SidebarRail`.
    var compact: Bool = false

    var body: some View {
        if compact {
            compactBody
        } else {
            VStack(spacing: 6) {
                expandedBody
                if !presentation.isAvailable {
                    ChromeButton(
                        "Abrir Ajustes", appearance: .outlined,
                        size: 11, height: 24, horizontalPadding: 9,
                        action: onOpenSettings
                    )
                    .help(presentation.detail)
                }
            }
        }
    }

    private var expandedBody: some View {
        Button(action: onOpenAssistant) {
            HStack(spacing: 10) {
                Image(systemName: presentation.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(statusColor.color)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.actionTitle)
                        .font(theme.sans.font(size: 12.5, weight: .semibold))
                        .foregroundStyle((presentation.isAvailable ? theme.ink : theme.ink3).color)
                    Text(presentation.scopeLabel)
                        .font(theme.sans.font(size: 10.5))
                        .foregroundStyle(theme.ink3.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Circle()
                    .fill(presentation.isAvailable ? statusColor.color : theme.ink4.color)
                    .frame(width: 6, height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 12)
            .background(presentation.isAvailable ? statusColor.color.opacity(0.08) : theme.surface3.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusLarge)
                    .strokeBorder(
                        presentation.isAvailable ? statusColor.color.opacity(0.28) : theme.line2.color,
                        lineWidth: Hairline.thickness(displayScale)
                    )
            }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusLarge)
        .disabled(!presentation.isAvailable)
        .help(presentation.actionHelp)
        .accessibilityLabel(presentation.actionTitle)
        .accessibilityValue(presentation.isAvailable ? "Disponível" : "Indisponível")
        .accessibilityHint(presentation.actionHelp)
    }

    /// Na trilha não cabe um segundo botão. Então o próprio acento da IA vira
    /// a saída: sem provedor pronto ele não fica mudo, leva a Configurações —
    /// e `help` e acessibilidade dizem isso antes do clique.
    private var compactAction: () -> Void {
        presentation.isAvailable ? onOpenAssistant : onOpenSettings
    }

    private var compactHelp: String {
        presentation.isAvailable
            ? presentation.actionHelp
            : "\(presentation.detail) Clique para abrir Ajustes."
    }

    private var compactBody: some View {
        Button(action: compactAction) {
            VStack(spacing: 4) {
                Image(systemName: presentation.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                Text("IA")
                    .font(theme.sans.font(size: 9, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(presentation.isAvailable ? statusColor.color : theme.ink4.color)
            .frame(width: 46, height: 50)
            .background(presentation.isAvailable ? statusColor.color.opacity(0.08) : theme.surface3.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(
                        presentation.isAvailable ? statusColor.color.opacity(0.28) : theme.line2.color,
                        lineWidth: Hairline.thickness(displayScale)
                    )
            }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .help(compactHelp)
        .accessibilityLabel(presentation.isAvailable ? presentation.actionTitle : "Abrir Ajustes")
        .accessibilityValue(presentation.isAvailable ? "Disponível" : "Indisponível")
        .accessibilityHint(compactHelp)
    }

    private var statusColor: TokenColor {
        presentation.isAvailable ? theme.info : theme.ink4
    }
}

/// "Nenhum controle mudo": a fila parada aparece com o motivo e um botão
/// que religa de verdade, como a fila de saída do Marco 3.
struct AnalysisPausedBand: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    /// A cópia é a promessa que fica na tela; trocá-la merece revisão.
    static let title = "ANÁLISE PAUSADA"
    static let retryTitle = "Tentar de novo"

    let reason: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.title)
                .capsLabel(size: 8.5)
            Text(reason)
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
            ChromeButton(Self.retryTitle, appearance: .outlined,
                         size: 11, height: 24, horizontalPadding: 9,
                         action: onRetry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .top)
        .accessibilityIdentifier("analysis-paused-band")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Análise automática pausada. \(reason)")
    }
}

public struct FolderSidebar: View {
    /// A largura canônica mora em `PaneLayout`, que é quem decide o que cabe.
    /// Este nome continua existindo porque o resto do shell já o usa — mas ele
    /// agora é um apelido, não uma segunda fonte da verdade.
    public static let expandedWidth: CGFloat = PaneLayout.expandedSidebarWidth

    /// A seta que abre as pastas de uma conta, em números.
    ///
    /// Ela nasceu na M3-17 com 9pt de corpo, tinta `ink4` e um alvo de 10
    /// pontos de largura — e o dono **quase não a viu**. Estes três números são
    /// o conserto da M3-21, e estão aqui com nome porque presença é
    /// comportamento: um teste os afirma sem montar barra nenhuma, e voltar
    /// atrás por acidente passa a custar um vermelho.
    ///
    /// Nada disso é componente novo: 11pt e `ink3` são o corpo e a tinta do
    /// cabeçalho de seção da janela 04, e o alvo com fundo no hover é o mesmo
    /// do × do canto dela. Visível, não gritante.
    nonisolated static let chevronSize: CGFloat = 11
    nonisolated static let chevronTargetWidth: CGFloat = 18
    nonisolated static let chevronTargetHeight: CGFloat = 24

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let store: MailStore

    /// A largura resolvida que a janela concedeu. O padrão é a canônica, para
    /// que previews e testes não precisem calcular layout.
    let width: CGFloat

    /// A apresentação vem do compositor do app. O padrão preserva os pontos
    /// de chamada existentes até que ele conecte o estado real do motor.
    let intelligencePresentation: IntelligencePresentation

    /// A fila de análise automática parada, com o motivo e o religar. `nil`
    /// quando ela está correndo — que é o caso normal.
    let analysisPause: AnalysisPauseState?

    /// A janela dona da navegação decide como apresentar o painel. A barra
    /// apenas entrega uma intenção — não conhece Foundation Models nem o motor
    /// que vai responder.
    let onOpenAssistant: () -> Void
    /// Abre Configurações quando o assistente ainda não pode responder.
    let onOpenSettings: () -> Void
    let onCompose: (() -> Void)?
    let onOpenAccounts: (() -> Void)?

    /// Qual caixa está esperando a confirmação de "Esvaziar lixeira".
    ///
    /// É o **único** destrutivo sem volta do app, e o único que pergunta antes.
    /// Arquivar, apagar e apagar definitivamente têm "Desfazer"; este não tem,
    /// e a pergunta é o que fica no lugar dele.
    @State private var confirmingEmptyTrash = false
    /// Sobre qual seta de conta o mouse está. Uma só por vez, e por isso um
    /// `id` e não um `Bool` por linha.
    @State private var chevronHovering: String?

    public init(
        store: MailStore,
        width: CGFloat = PaneLayout.expandedSidebarWidth,
        intelligencePresentation: IntelligencePresentation = .onThisMac,
        analysisPause: AnalysisPauseState? = nil,
        onOpenAssistant: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onCompose: (() -> Void)? = nil,
        onOpenAccounts: (() -> Void)? = nil
    ) {
        self.store = store
        self.width = width
        self.intelligencePresentation = intelligencePresentation
        self.analysisPause = analysisPause
        self.onOpenAssistant = onOpenAssistant
        self.onOpenSettings = onOpenSettings
        self.onCompose = onCompose
        self.onOpenAccounts = onOpenAccounts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if onCompose != nil {
                composeButton
                    .padding(.horizontal, 10)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Seção "Fluxo"
                    sectionHeader("Fluxo", padding: EdgeInsets(top: 0, leading: 16, bottom: 7, trailing: 16))
                    // Protótipo: a lista tem `padding: 0 8px; gap: 1px`, e cada
                    // linha tem os seus próprios `padding: 0 8px`. É essa soma
                    // que põe o rótulo da pasta na mesma coluna do "FLUXO", em
                    // 16pt — sem ela a linha nasce em 8 e o realce sangra até a
                    // borda da barra.
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(TriageBucket.allCases, id: \.self) { bucket in
                            bucketRow(bucket)
                        }
                    }
                    .padding(.horizontal, 8)

                    // Seção "Caixas"
                    if !store.accounts.isEmpty {
                        sectionHeader("Caixas", padding: EdgeInsets(top: 22, leading: 16, bottom: 7, trailing: 16))
                        VStack(alignment: .leading, spacing: 2) {  // protótipo: gap: 2px
                            ForEach(store.accounts) { account in
                                accountRow(account)
                                // As pastas do provedor, quando a conta está
                                // aberta. Elas ficam **dentro** da seção
                                // CAIXAS, logo abaixo da conta a que pertencem:
                                // uma seção própria as separaria da conta e a
                                // barra teria de repetir o endereço em cada
                                // grupo.
                                if store.foldersExpanded(account.id) {
                                    ForEach(store.folders(of: account.id)) { folder in
                                        folderRow(folder, account: account)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, onCompose == nil ? 14 : 0)
            }

            // Rodapé fixo
            // `Divider()` não é a divisória deste design: ele pinta a cor do
            // separador do sistema (medido, `rgb(202,199,192)`) por baixo do
            // fundo pedido, e sai 22 níveis mais escuro que `--line`. Era o
            // único traço da tela fora do idioma da hairline.
            Rectangle()
                .fill(theme.line.color)
                .frame(height: Hairline.thickness(displayScale))
            if let analysisPause {
                AnalysisPausedBand(
                    reason: analysisPause.reason,
                    onRetry: analysisPause.retry
                )
            }
            VStack(spacing: 8) {
                IntelligenceFooter(
                    presentation: intelligencePresentation,
                    onOpenAssistant: onOpenAssistant,
                    onOpenSettings: onOpenSettings
                )
                if onOpenAccounts != nil {
                    accountsButton
                }
            }
            .padding(10)
        }
        // A barra ocupa toda a altura que o painel conceder. Sem esse limite,
        // um rodapé com três linhas pode disputar a altura ideal com o
        // `ScrollView` e esmagar a lista acima dele no primeiro passe.
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .trailing)
    }

    private var composeButton: some View {
        Button { onCompose?() } label: {
            HStack(spacing: 9) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
                Text("Escrever")
                    .font(theme.sans.font(size: 13, weight: .semibold))
            }
            .foregroundStyle(theme.onAccent.color)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(theme.accent.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall, tint: \.onAccent)
        .help("Nova mensagem (⌘N)")
        .accessibilityLabel("Escrever uma nova mensagem")
    }

    private var accountsButton: some View {
        Button { onOpenAccounts?() } label: {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                Text("Contas e providers")
                    .font(theme.sans.font(size: 12.5, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.ink4.color)
            }
            .foregroundStyle(theme.ink2.color)
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .help("Gerenciar contas, providers e sincronização")
    }

    private func sectionHeader(_ title: String, padding: EdgeInsets) -> some View {
        Text(title)
            .capsLabel(size: 9.5)
            .padding(padding)
    }

    private func bucketRow(_ bucket: TriageBucket) -> some View {
        let active = bucket == store.bucket
        return Button { store.select(bucket: bucket) } label: {
            HStack(spacing: 9) {
                Image(systemName: Self.navigationSymbol(for: bucket))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle((active ? theme.ink : theme.ink3).color)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(bucket.label)
                    .font(theme.sans.font(size: 13, weight: .medium))
                    .foregroundStyle((active ? theme.ink : theme.ink2).color)
                Spacer(minLength: 0)
                Text("\(Self.counter(for: bucket, store: store))")
                    .font(theme.mono.font(size: 10))
                    .foregroundStyle((active ? theme.ink : theme.ink4).color)
            }
            .frame(height: 40)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background {
                if active {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .fill(theme.accentSoft.color)
                }
            }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        // Os itens da caixa somem quando não há o que fazer: caixa toda lida
        // não oferece "Marcar tudo como lido", Lixeira vazia não oferece
        // "Esvaziar lixeira". Aqui sumir é certo — ao contrário do menu da
        // mensagem, onde a lista de ações de topo tem de ser estável, o menu da
        // caixa existe só pelo que ela tem agora; uma linha apagada diria o
        // contrário do contador ao lado dela.
        .uniContextMenu(
            ContextMenus.bucketRow(
                bucket,
                unread: store.unreadCount(in: bucket, accountID: store.selectedAccountID),
                accountID: store.selectedAccountID,
                trash: store.trashCount(accountID: store.selectedAccountID)
            ),
            store: store,
            // "Esvaziar lixeira" não vai direto ao store: ele para aqui e
            // pergunta. É a troca que o item faz por não ter "Desfazer".
            intercept: { command in
                guard case .emptyTrash = command else { return false }
                confirmingEmptyTrash = true
                return true
            }
        )
        .modifier(EmptyTrashConfirmation(store: store, isPresented: $confirmingEmptyTrash))
    }

    /// O símbolo de uma caixa, quando ela tem um.
    ///
    /// Três têm, e pela mesma razão: elas são as que **não** são triagem. A
    /// Lixeira é a única cujo conteúdo se perde; Enviadas guarda o que saiu;
    /// Rascunhos guarda o que ainda não saiu. O ícone é o que as distingue à
    /// primeira vista de "Arquivado". As outras quatro continuam só com o
    /// nome, como no protótipo.
    static func symbol(for bucket: TriageBucket) -> String? {
        switch bucket {
        case .trash: "trash"
        case .junk: "exclamationmark.octagon"
        case .sent: "paperplane"
        case .drafts: "square.and.pencil"
        default: nil
        }
    }

    private static func navigationSymbol(for bucket: TriageBucket) -> String {
        switch bucket {
        case .today: "sun.max"
        case .later: "clock"
        case .all: "tray"
        case .archived: "archivebox"
        case .trash: "trash"
        case .junk: "exclamationmark.octagon"
        case .sent: "paperplane"
        case .drafts: "square.and.pencil"
        }
    }

    /// O número que a caixa mostra à direita.
    ///
    /// Não lidas em toda caixa da triagem — é o que o dono pediu, e o que o
    /// webmail mostra. **Menos em Enviadas**, que mostra o total: uma mensagem
    /// que você escreveu nasce lida, então "não lidas" ali seria zero para
    /// sempre — um contador que nunca se move é ruído com cara de informação.
    static func counter(for bucket: TriageBucket, store: MailStore) -> Int {
        bucket == .sent || bucket == .drafts
            ? store.count(for: bucket)
            : store.unreadCount(in: bucket, accountID: store.selectedAccountID)
    }

    /// A linha de uma pasta do provedor, dentro da conta aberta.
    ///
    /// Ela recua 14pt em relação à linha da conta — o mesmo recuo que a seta
    /// ocupa lá em cima — e é isso que diz "esta pasta é daquela conta" sem
    /// precisar de moldura, linha guia nem repetir o endereço.
    private func folderRow(_ folder: MailFolder, account: Account) -> some View {
        let active = folder.id == store.selectedFolderID
        let tintColor = account.tint(isDark: theme.isDark)

        return Button { store.select(folder: folder.id) } label: {
            HStack(spacing: 7) {
                // O ícone só existe para a pasta de papel conhecido — lixeira,
                // enviadas, rascunhos, spam. A que a pessoa criou não tem
                // nenhum, e um ícone genérico ao lado de todas roubaria o sinal
                // das que têm um. Ver `MailFolder.symbol`.
                Group {
                    if let symbol = folder.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 10))
                            .foregroundStyle((active ? theme.ink : theme.ink4).color)
                    }
                }
                .frame(width: 12)
                .accessibilityHidden(true)

                Text(folder.displayName)
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle((active ? theme.ink : theme.ink2).color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // O caminho inteiro no `help`: a linha corta pelo meio uma
                    // subpasta longa ("Clientes/2026/Faturas"), e o balão é
                    // onde ele cabe sem alargar a barra.
                    .help(folder.serverName)

                Spacer(minLength: 0)

                // Zero não é desenhado: uma coluna de zeros ao lado de doze
                // pastas é ruído com cara de informação, e o que importa numa
                // pasta é justamente ela ter alguma coisa por ler.
                if folder.unreadCount > 0 {
                    Text("\(folder.unreadCount)")
                        .font(theme.mono.font(size: 10))
                        .foregroundStyle((active ? theme.ink : theme.ink4).color)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .padding(.leading, 22)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
            .background {
                if active {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .fill(opacityMix(tintColor, 16))
                }
            }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
    }

    private func accountRow(_ account: Account) -> some View {
        let active = account.id == store.selectedAccountID
        let tintColor = account.tint(isDark: theme.isDark)
        let tintTokenColor = TokenColor(css: tintColor) ?? theme.ink4
        // **A seta só existe quando há pasta.** Sem conta conectada — as
        // fixtures — não há pasta de provedor nenhuma, e a linha da conta fica
        // exatamente como o Marco 1 a desenhava, até o pixel. É a mesma regra
        // que o app inteiro segue: sem conta, nada muda.
        let pastas = store.folders(of: account.id)

        return Button { store.select(account: account.id) } label: {
            HStack(spacing: 8) {
                if !pastas.isEmpty {
                    // A seta é o idioma de recolhível desta base — o mesmo "▾"
                    // aberto / "▸" fechado do cabeçalho de seção da janela de
                    // compromisso (M3-13), e não um `DisclosureGroup`, que traz
                    // desenho e espaçamento próprios do sistema.
                    //
                    // Ela **não** é um botão dentro de um botão: é um alvo de
                    // toque desenhado dentro do rótulo, com o gesto próprio por
                    // cima. Um `Button` aninhado teria dois estilos, dois anéis
                    // de foco e um clique que às vezes chega ao de fora.
                    // **Com presença, desde a M3-21.** Ela nasceu em 9pt,
                    // `ink4`, num alvo de 10 pontos de largura e sem nenhuma
                    // resposta ao mouse — o dono quase não a viu. Três coisas
                    // mudaram, e nenhuma é um componente novo: o corpo (11pt),
                    // a tinta (`ink3`, a mesma que o cabeçalho de seção da
                    // janela 04 usa) e o alvo (18×24, com o fundo do hover que
                    // o × do canto daquela janela já desenha). Continua sendo
                    // a mesma seta no mesmo lugar — agora ela se oferece.
                    Text(store.foldersExpanded(account.id) ? "▾" : "▸")
                        .font(theme.mono.font(size: Self.chevronSize))
                        .foregroundStyle(
                            (chevronHovering == account.id ? theme.ink2 : theme.ink3).color
                        )
                        .frame(width: Self.chevronTargetWidth, height: Self.chevronTargetHeight)
                        .background(
                            chevronHovering == account.id ? theme.surface3.color : .clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                        .contentShape(Rectangle())
                        .onHover { chevronHovering = $0 ? account.id : nil }
                        .onTapGesture { store.toggleFolders(of: account.id) }
                        .accessibilityLabel(
                            store.foldersExpanded(account.id)
                                ? "Recolher as pastas de \(account.address)"
                                : "Mostrar as pastas de \(account.address)"
                        )
                }

                // Chip do host — o mesmo `chip()` do protótipo que a lista usa.
                TintChip(label: account.host, tint: tintTokenColor.color, emphasized: active)

                // Endereço
                Text(account.address)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink2.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(account.address)

                // O estado da conta na lateral, sem tirar espaço do endereço:
                // um ponto, com o `help` dizendo o que ele significa. Conta
                // parada sem sinal nenhum foi o defeito que a janela de Contas
                // existe para não repetir.
                if account.state != .ativa {
                    Circle()
                        .fill(account.state == .carregando ? theme.ink4.color : theme.accent.color)
                        .frame(width: 6, height: 6)
                        .help(account.state == .carregando
                            ? "Carregando as mensagens desta conta…"
                            : "Esta conta precisa ser reconectada. Abra Configurações…")
                }

                // Sem isto a linha mede o conteúdo, e como cada endereço tem um
                // comprimento diferente **cada seleção pintava uma largura
                // diferente** — e o contador ficava colado no endereço em vez de
                // alinhado à direita. A linha de pasta sempre teve este `Spacer`.
                Spacer(minLength: 0)

                // Contador (mensagens da conta)
                Text("\(store.count(forAccount: account.id))")
                    .font(theme.mono.font(size: 10))
                    .foregroundStyle(theme.ink4.color)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background {
                if active {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .fill(opacityMix(tintColor, 16))
                }
            }
            .overlay(alignment: .leading) {
                if active {
                    Rectangle()
                        .fill(tintTokenColor.color)
                        .frame(width: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .uniContextMenu(
            ContextMenus.accountRow(
                account,
                isFiltered: active,
                // A conta inteira, não a caixa aberta: a linha da conta não
                // pertence a caixa nenhuma.
                unread: store.unreadCount(in: .all, accountID: account.id)
            ),
            store: store
        )
    }

    private func opacityMix(_ hexColor: String, _ percentage: Int) -> Color {
        // Simulates: color-mix(in oklab, hexColor percentage%, transparent)
        // In SwiftUI, we use opacity as approximation
        guard let tokenColor = TokenColor(css: hexColor) else {
            return Color.clear
        }
        return tokenColor.color.opacity(Double(percentage) / 100.0)
    }

}

/// A pausa da fila de análise automática, na forma que a tela consome: o
/// motivo já traduzido pelo coordenador e a ação que religa de verdade.
///
/// Existe como tipo, e não como tupla, porque três superfícies a recebem e
/// uma tupla anônima faria cada uma inventar a própria ordem dos campos.
public struct AnalysisPauseState {
    public let reason: String
    public let retry: () -> Void

    public init(reason: String, retry: @escaping () -> Void) {
        self.reason = reason
        self.retry = retry
    }
}

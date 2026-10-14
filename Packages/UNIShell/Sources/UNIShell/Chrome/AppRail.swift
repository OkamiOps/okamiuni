import SwiftUI
import UNICore
import UNIDesign

/// O trilho de 64pt na ponta esquerda da janela: semáforos no alto, as três
/// telas, e no pé a IA, o interruptor de aparência, Configurações e o avatar.
///
/// Ele **substitui a barra do topo** (`WindowChrome`) na janela principal. A
/// barra não foi apagada: as outras cinco janelas do app continuam com a
/// `WindowTitleBar` delas, e o `WindowChrome` segue existindo para quem o
/// chama. O que mudou é quem navega — e navegar numa barra horizontal de 64pt
/// custava uma faixa inteira de altura para três abas.
///
/// Protótipo: `Sidebar.dc.html`, `<nav aria-label="Telas">`.
struct AppRail: View {
    /// Largura canônica. O protótipo pede 64; os quadrados de ação têm 40 e a
    /// legenda de 10pt cabe embaixo deles.
    static let width: CGFloat = PaneLayout.appRailWidth

    /// Lado do quadrado de uma ação do trilho.
    static let actionSize: CGFloat = 40
    static let actionRadius: CGFloat = 12

    @Environment(\.theme) private var theme
    @Environment(ThemeStore.self) private var themeStore

    let store: MailStore
    @Binding var workspace: Workspace
    /// A trilha carrega a mesma porta da IA que a barra larga.
    let intelligencePresentation: IntelligencePresentation
    let onOpenAssistant: () -> Void
    let onOpenSettings: () -> Void
    let accountMonogram: String
    /// A sincronização está em pé? É o pontinho verde no canto do avatar.
    let isSynced: Bool

    var body: some View {
        VStack(spacing: 6) {
            // O vazio em que os semáforos nativos da janela são desenhados.
            // Eles não são `View` nossa — moram no `NSThemeFrame` — então o
            // que o trilho reserva é o lugar deles. Ver
            // `TrafficLightLayout.railLeading`.
            Color.clear
                .frame(height: AppRail.trafficLightReserve)
                .accessibilityHidden(true)

            ForEach(Workspace.allCases, id: \.self) { tab in
                navigationButton(tab)
            }

            Spacer(minLength: 8)

            assistantButton
            // `theme.isDark` do ambiente, e não `themeStore.isDark`: o que o
            // interruptor mostra é o tema que **esta janela está desenhando**.
            // São o mesmo valor no app; no harness fora da tela o tema vem
            // injetado e a loja fica no padrão, e aí a lua apareceria
            // desligada num retrato escuro.
            ThemeSwitch(isDark: theme.isDark) { themeStore.toggleAppearance() }
                .padding(.vertical, 2)
            settingsButton
            avatar
        }
        .frame(width: AppRail.width)
        .frame(maxHeight: .infinity)
        .padding(.vertical, 12)
    }

    /// Quanto o trilho guarda no alto para os três botões do sistema.
    ///
    /// `contentCenterFromTop` é a linha em que a plataforma põe o centro deles
    /// contada do topo **da janela**; o trilho começa `PanelStyle.vidroGap`
    /// abaixo disso, e os 12pt de `padding(.vertical)` já entram antes. O que
    /// resta é a folga para a primeira tela não encostar nas bolinhas.
    static let trafficLightReserve: CGFloat = 18

    /// A faixa do alto da janela em que o duplo clique faz o que o sistema
    /// manda e o arraste move a janela. Ela cobre a altura dos semáforos com
    /// folga e para antes do primeiro botão de tela.
    static let dragStripHeight: CGFloat = 42

    // MARK: - Navegação

    private func navigationButton(_ tab: Workspace) -> some View {
        let active = tab == workspace
        let badge = tab == .mail ? store.unreadCount(in: .today) : 0
        return Button { workspace = tab } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol(for: tab))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle((active ? theme.accentInk : theme.ink2).color)
                        .frame(width: AppRail.actionSize, height: AppRail.actionSize)
                        .background {
                            RoundedRectangle(cornerRadius: AppRail.actionRadius, style: .continuous)
                                .fill(active ? theme.surface.color : Color.clear)
                        }
                    if badge > 0, !active {
                        BadgeDot(count: badge)
                            .offset(x: 5, y: -4)
                    }
                }
                Text(tab.label)
                    .font(theme.sans.font(size: 10, weight: active ? .semibold : .medium))
                    .foregroundStyle((active ? theme.ink : theme.ink3).color)
                    .lineLimit(1)
            }
            .frame(width: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: AppRail.actionRadius)
        .help(tab.label)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func symbol(for tab: Workspace) -> String {
        switch tab {
        case .dashboard: "square.grid.2x2"
        case .mail: "tray.full"
        case .calendar: "calendar"
        }
    }

    // MARK: - O pé do trilho

    /// O ✦ do protótipo, que abre a gaveta do ⌘J. Quando a IA ainda não pode
    /// responder, o mesmo botão leva a Configurações — a saída que a
    /// `SidebarRail` já usava, pelo mesmo motivo: um botão apagado sem
    /// caminho para consertar o estado é um beco.
    private var assistantButton: some View {
        let available = intelligencePresentation.isAvailable
        return Button(action: available ? onOpenAssistant : onOpenSettings) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle((available ? theme.accentInk : theme.ink4).color)
                .frame(width: AppRail.actionSize, height: AppRail.actionSize)
                .background {
                    RoundedRectangle(cornerRadius: AppRail.actionRadius, style: .continuous)
                        .fill(available ? theme.accentSoft.color : theme.surface3.color)
                }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: AppRail.actionRadius)
        .help(
            available
                ? L10n.tr("Perguntar à IA (⌘J)")
                : L10n.tr("\(intelligencePresentation.detail) Clique para abrir Ajustes.")
        )
        .accessibilityLabel(
            available ? L10n.tr("Perguntar à IA") : L10n.tr("Abrir Ajustes")
        )
    }

    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.ink2.color)
                .frame(width: AppRail.actionSize, height: AppRail.actionSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: AppRail.actionRadius)
        .help(L10n.tr("Contas e providers"))
        .accessibilityLabel(L10n.tr("Abrir contas e providers"))
    }

    /// O monograma da conta, com o ponto verde da sincronização. Ele abre a
    /// mesma janela que o avatar da barra antiga abria.
    private var avatar: some View {
        Button(action: onOpenSettings) {
            Text(accountMonogram)
                .font(theme.sans.font(size: 11, weight: .semibold))
                .foregroundStyle(theme.paper.color)
                .frame(width: 30, height: 30)
                .background(theme.ink.color)
                .clipShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    if isSynced {
                        Circle()
                            .fill(theme.success.color)
                            .frame(width: 9, height: 9)
                            .overlay {
                                Circle().strokeBorder(theme.paper.color, lineWidth: 1.5)
                            }
                            .offset(x: 1, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .focusRing(in: Circle())
        .help(L10n.tr("Contas e providers"))
        .accessibilityLabel(L10n.tr("Abrir contas e providers"))
        .accessibilityValue(isSynced ? L10n.tr("sincronizado") : L10n.tr("sem sincronizar"))
    }
}

/// O número de não lidas no canto do ícone da Caixa.
struct BadgeDot: View {
    @Environment(\.theme) private var theme
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(theme.sans.font(size: 9.5, weight: .bold))
            .foregroundStyle(theme.onAccent.color)
            .padding(.horizontal, count > 9 ? 4 : 0)
            .frame(minWidth: 16, minHeight: 16)
            .background(theme.accent.color)
            .clipShape(Capsule())
            .accessibilityLabel(L10n.tr("\(count) não lidas"))
    }
}

/// O interruptor vertical do protótipo: sol em cima, lua embaixo, botão que
/// desliza entre os dois. É ele que troca claro ↔ escuro — ver
/// `Theme.appearanceCounterpart`.
///
/// Vertical, e não o `Toggle` do sistema: num trilho de 64pt um interruptor
/// deitado não cabe, e o do sistema não aceita os dois glifos nas pontas.
struct ThemeSwitch: View {
    static let size = CGSize(width: 32, height: 58)

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let isDark: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            ZStack(alignment: .top) {
                Capsule()
                    .fill(theme.surface3.color)
                    .overlay {
                        Capsule().strokeBorder(
                            theme.line.color, lineWidth: Hairline.thickness(displayScale)
                        )
                    }

                Circle()
                    .fill(theme.surface.color)
                    .frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 2)
                    .padding(.top, isDark ? Self.size.height - 29 : 3)

                VStack(spacing: 0) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle((isDark ? theme.ink3 : theme.warning).color)
                        .frame(height: Self.size.height / 2)
                    Image(systemName: "moon.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle((isDark ? theme.accentInk : theme.ink3).color)
                        .frame(height: Self.size.height / 2)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusRing(in: Capsule())
        .animation(.easeOut(duration: 0.18), value: isDark)
        .help(isDark ? L10n.tr("Mudar para o tema claro") : L10n.tr("Mudar para o tema escuro"))
        .accessibilityLabel(L10n.tr("Tema escuro"))
        .accessibilityValue(isDark ? L10n.tr("ligado") : L10n.tr("desligado"))
        .accessibilityAddTraits(.isToggle)
    }
}

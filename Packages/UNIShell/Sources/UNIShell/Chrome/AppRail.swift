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

    /// Largura do alvo de uma tela. Protótipo: `width: 52px` no `<a>`, com o
    /// quadrado de 40 centrado nele — sobram 6pt de cada lado, e é essa folga
    /// que o selo de não lidas usa.
    static let itemWidth: CGFloat = 52

    // As medidas do `<nav>` com nome, para o teste poder somá-las em vez de
    // repetir números à mão. Protótipo: `padding: 14px 0 12px; gap: 6px` no
    // `<nav>`, e `padding: 2px 0 4px; gap: 4px` em cada `<a>`.
    static let topPadding: CGFloat = 14
    static let bottomPadding: CGFloat = 12
    static let gap: CGFloat = 6
    static let itemTopPadding: CGFloat = 2
    static let itemBottomPadding: CGFloat = 4
    static let itemSpacing: CGFloat = 4
    /// Altura da legenda de 10pt. É o que o SwiftUI dá a uma linha nesse
    /// corpo, e é o que o `line-height: normal` do protótipo dá à dele.
    static let labelHeight: CGFloat = 12

    /// Altura de uma tela do trilho, legenda inclusa.
    static var itemHeight: CGFloat {
        itemTopPadding + actionSize + itemSpacing + labelHeight + itemBottomPadding
    }
    /// Distância de centro a centro entre duas telas.
    static var itemPitch: CGFloat { itemHeight + gap }

    /// Quanto o selo de não lidas recua da aresta do quadrado do ícone.
    ///
    /// Protótipo: `top: 0; right: 6px` no `<a>` de 52pt, o que põe a caixa de
    /// 16 do selo com a aresta direita na aresta direita do quadrado e o topo
    /// 2pt acima dele — mais o anel de 2pt que ela desenha para fora. Daí o
    /// `offset(x: 2, y: -4)` de `navigationButton`.
    nonisolated static let badgeInset: CGFloat = 2

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
    /// Há atualização pronta? Com a coluna de contexto recolhida o cartão dela
    /// não está na tela, e o protótipo põe o ícone no pé do trilho, acima do
    /// ✦ — `sc-if value="{{closed}}"`.
    var updates: UpdateController? = nil
    /// A coluna de contexto está recolhida? É o que decide se o ícone da
    /// atualização aparece aqui.
    var contextCollapsed: Bool = false
    /// Clicar na tela que já está no ar, com a coluna recolhida, abre a coluna
    /// de volta. É a única porta que o trilho tem para ela: o botão
    /// `sidebar.left` mora no cabeçalho do primeiro painel de conteúdo, não
    /// aqui — ver o protótipo, que nunca desenhou controle de expandir no
    /// trilho.
    var onReopenContext: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: AppRail.gap) {
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

            Spacer(minLength: 0)

            // Protótipo: com a coluna recolhida o ícone da atualização entra
            // **acima** do ✦. Com a coluna aberta quem avisa é o cartão do pé
            // dela, e dois avisos da mesma coisa na mesma tela é um a mais.
            if contextCollapsed, let updates, updates.showsReadyButton {
                updateButton(updates)
            }

            // Protótipo: `margin-bottom: 2px` no ✦ e `margin: 4px 0 6px` no
            // interruptor — com o `gap: 6px` do trilho isso dá 12pt entre o ✦
            // e o interruptor, 12 entre o interruptor e a engrenagem e 10 até
            // o avatar.
            assistantButton
                .padding(.bottom, 2)
            // `theme.isDark` do ambiente, e não `themeStore.isDark`: o que o
            // interruptor mostra é o tema que **esta janela está desenhando**.
            // São o mesmo valor no app; no harness fora da tela o tema vem
            // injetado e a loja fica no padrão, e aí a lua apareceria
            // desligada num retrato escuro.
            ThemeSwitch(isDark: theme.isDark) { themeStore.toggleAppearance() }
                .padding(.top, 4)
                .padding(.bottom, 6)
            settingsButton
            avatar
                .padding(.top, 4)
        }
        .frame(width: AppRail.width)
        .frame(maxHeight: .infinity)
        // Protótipo: `padding: 14px 0 12px` no `<nav>`.
        .padding(.top, AppRail.topPadding)
        .padding(.bottom, AppRail.bottomPadding)
    }

    /// Quanto o trilho guarda no alto para os três botões do sistema.
    ///
    /// Protótipo: a fila é um `<div>` com `padding: 2px 0 16px`. O que ele
    /// embrulha, aqui, não são as bolinhas de 11 do desenho mas os botões de
    /// 14 do macOS — então a faixa é `2 + 14 + 16`, e não `2 + 11 + 16`.
    ///
    /// Copiar os 29 do desenho com botões de 14 tirava 3pt de folga de quem os
    /// tem de verdade: eles subiam para dentro da quina arredondada do painel,
    /// que é o que o dono recusou em 14/10/2026. Ver
    /// `TrafficLightLayout.railCenterFromTop`, que faz a mesma tradução.
    static let trafficLightReserve: CGFloat =
        2 + TrafficLightLayout.nativeButtonSide + 16  // 32

    /// A faixa do alto da janela em que o duplo clique faz o que o sistema
    /// manda e o arraste move a janela. Ela cobre a altura dos semáforos com
    /// folga e para antes do primeiro botão de tela.
    static let dragStripHeight: CGFloat = 42

    // MARK: - Navegação

    private func navigationButton(_ tab: Workspace) -> some View {
        let active = tab == workspace
        let badge = tab == .mail ? store.unreadCount(in: .today) : 0
        return Button {
            // Clicar na tela que já está no ar, com a coluna recolhida,
            // também a abre de volta.
            if active, let onReopenContext { onReopenContext() } else { workspace = tab }
        } label: {
            VStack(spacing: AppRail.itemSpacing) {
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
                        // Ver `AppRail.badgeInset`: o anel de 2pt fica para
                        // fora do quadrado à direita e o topo do selo sobe 2pt
                        // acima dele, dentro dos 6pt de folga que os 52 do
                        // alvo deixam. Ele não alcança a legenda da tela de
                        // cima, que é o que acontecia quando o selo subia 4.
                        BadgeDot(count: badge)
                            .offset(x: AppRail.badgeInset, y: -2 * AppRail.badgeInset)
                    }
                }
                Text(tab.label)
                    .font(theme.sans.font(size: 10, weight: active ? .semibold : .medium))
                    .foregroundStyle((active ? theme.ink : theme.ink3).color)
                    .lineLimit(1)
            }
            // Protótipo: `width: 52px; padding: 2px 0 4px`.
            .frame(width: AppRail.itemWidth)
            .padding(.top, AppRail.itemTopPadding)
            .padding(.bottom, AppRail.itemBottomPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: AppRail.actionRadius)
        .help(tab.label)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// O ícone da atualização pronta, com o pontinho de acento no canto.
    /// Protótipo: `sc-if value="{{closed}}"`, 40×40, seta em `accentInk` e o
    /// ponto de 8pt em `top: 7px; right: 7px`.
    private func updateButton(_ updates: UpdateController) -> some View {
        Button { updates.openPanel() } label: {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(theme.accentInk.color)
                .frame(width: AppRail.actionSize, height: AppRail.actionSize)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(theme.accent.color)
                        .frame(width: 8, height: 8)
                        .padding(7)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: AppRail.actionRadius)
        .help(L10n.tr("Atualização pronta"))
        .accessibilityLabel(L10n.tr("Atualização pronta"))
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
            // Protótipo: 32pt de diâmetro, monograma de 12 e o ponto de 9 com
            // anel de 2 no canto.
            Text(accountMonogram)
                .font(theme.sans.font(size: 12, weight: .semibold))
                .foregroundStyle(theme.paper.color)
                .frame(width: 32, height: 32)
                .background(theme.ink.color)
                .clipShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    if isSynced {
                        Circle()
                            .fill(theme.success.color)
                            .frame(width: 9, height: 9)
                            .overlay {
                                Circle().strokeBorder(theme.paper.color, lineWidth: 2)
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
        // Protótipo: caixa de 16 com `border: 2px solid {{t.badgeRing}}` em
        // `content-box` — o anel fica **para fora** dos 16, não comendo deles.
        Text(count > 99 ? "99+" : "\(count)")
            .font(theme.sans.font(size: 9.5, weight: .bold))
            .foregroundStyle(theme.onAccent.color)
            .padding(.horizontal, count > 9 ? 4 : 0)
            .frame(minWidth: 16, minHeight: 16)
            .background(theme.accent.color, in: Capsule())
            .padding(2)
            .background(theme.paper.color, in: Capsule())
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
    /// Protótipo: `width: 34px; height: 62px; border-radius: 17px`, com o
    /// botão de 28 e 2pt de folga em volta dele.
    static let size = CGSize(width: 34, height: 62)
    static let knob: CGFloat = 28

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
                    .frame(width: Self.knob, height: Self.knob)
                    .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 2)
                    .padding(.top, isDark ? Self.size.height - Self.knob - 2 : 2)

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

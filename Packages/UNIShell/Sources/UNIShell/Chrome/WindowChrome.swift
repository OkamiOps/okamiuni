import SwiftUI
import UNIDesign
import UNICore

public enum Workspace: String, CaseIterable, Sendable {
    case mail, calendar

    public var label: String {
        switch self {
        case .mail: "Caixa"
        case .calendar: "Agenda"
        }
    }
}

/// Os controles da barra, na ordem em que aparecem da esquerda para a direita.
///
/// Isto não é documentação: `WindowChrome.body` percorre `controlOrder` para
/// montar o `HStack`, então mudar a lista muda o que a janela desenha — e o
/// teste que trava a lista trava a barra.
public enum ChromeControl: String, CaseIterable, Sendable {
    case sidebarToggle, tabs, search, agendaToggle, lockup, themePicker
}

public struct WindowChrome: View {
    public static let height: CGFloat = 58

    /// **Divergência deliberada do protótipo, pedida pelo dono do projeto.** No
    /// protótipo o lockup abre a barra, à esquerda dos semáforos para dentro.
    /// Aqui ele fecha a barra, encostado no seletor de temas: a esquerda fica
    /// só com os semáforos, o botão da lateral e as abas, encostados, no ritmo
    /// do Chrome e do app do Claude — as duas referências que ele deu.
    public static let controlOrder: [ChromeControl] = [
        .sidebarToggle,
        .tabs,
        .search,
        .agendaToggle,
        .lockup,
        .themePicker,
    ]

    /// O único controle que cede largura. Os outros medem o que precisam; este
    /// come a folga em janela larga e é o primeiro a encolher em janela
    /// estreita.
    public static let flexibleControl: ChromeControl = .search

    /// A linha média da barra, onde tudo o que ela desenha fica centrado — e,
    /// desde a Task S, também os semáforos nativos.
    public static let centerY: CGFloat = 29
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

    /// Raio dos cantos das abas Caixa/Agenda. O protótipo usa o mesmo `var(--r2)`
    /// no container e na aba ativa, e alguns temas o definem como 0 — subtrair
    /// daqui produziria raio negativo.
    public static func tabCornerRadius(for theme: Theme) -> CGFloat {
        theme.radiusSmall
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

    /// A largura do campo de busca no protótipo. Aqui é um teto, não uma
    /// largura: em 1440 sobra espaço e o campo o alcança, ficando idêntico.
    public static let searchIdealWidth: CGFloat = 400

    /// Abaixo disto o campo deixa de ser usável — o placeholder trunca e o
    /// "⌘K" encosta no cursor. A partir daqui quem cede é a folga do `HStack`.
    public static let searchMinimumWidth: CGFloat = 150

    @Environment(\.theme) private var theme
    @Binding var workspace: Workspace
    @Binding var query: String
    let accountCount: Int
    let onToggleSidebar: () -> Void
    let onToggleAgenda: () -> Void
    @State private var sidebarHovering = false
    @State private var agendaHovering = false

    public init(
        workspace: Binding<Workspace>,
        query: Binding<String>,
        accountCount: Int,
        onToggleSidebar: @escaping () -> Void,
        onToggleAgenda: @escaping () -> Void
    ) {
        self._workspace = workspace
        self._query = query
        self.accountCount = accountCount
        self.onToggleSidebar = onToggleSidebar
        self.onToggleAgenda = onToggleAgenda
    }

    public var body: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: Self.trafficLightInset - 14, height: 1)

            ForEach(Self.controlOrder, id: \.self) { control in
                view(for: control)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.height)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .bottom)
        // Sobe os semáforos nativos para a linha média da barra. Tamanho zero e
        // sem hit test: não participa do layout nem come clique.
        .overlay(alignment: .topLeading) {
            TrafficLightAlignment(barHeight: Self.height)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func view(for control: ChromeControl) -> some View {
        switch control {
        case .sidebarToggle: sidebarToggle
        case .tabs: workspaceTabs
        case .search:
            searchField
                // Protótipo: `flex: 1; justify-content: center` em volta do
                // campo. O campo em si tem uma faixa, não uma largura: em 1440
                // ele bate no teto de 400 e fica idêntico ao protótipo; numa
                // janela estreita ele cede antes de espremer as abas.
                .frame(maxWidth: .infinity)
        case .agendaToggle: agendaToggle
        case .lockup: lockup
        case .themePicker: ThemePicker()
        }
    }

    private var lockup: some View {
        Image(theme.isDark ? "uni-lockup-dark" : "uni-lockup-light", bundle: Bundle.main)
            .resizable()
            .scaledToFit()
            .frame(height: 38)
            .accessibilityLabel("OkamiUNI")
    }

    private var sidebarToggle: some View {
        Button(action: onToggleSidebar) {
            HStack(spacing: 2.5) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.ink3.color)
                    .frame(width: 3, height: 11)
                RoundedRectangle(cornerRadius: 1)
                    .strokeBorder(theme.ink4.color, lineWidth: 0.5)
                    .frame(width: 7, height: 11)
            }
            .frame(width: 26, height: 24)
            .background(theme.btn.color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(sidebarHovering ? theme.accent.color : theme.btnLine.color, lineWidth: 0.5)
            }
            .shadow(theme.btnShadow)
        }
        .buttonStyle(.plain)
        .onHover { sidebarHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: sidebarHovering)
        .accessibilityLabel("Mostrar ou esconder a barra lateral")
    }

    /// O protótipo não tem este controle: nele a agenda está sempre visível
    /// porque a página só existe em 1440. Aqui ela sai sozinha abaixo de 1360,
    /// e sem um botão o usuário perderia a função sem meio de recuperá-la.
    /// O desenho é o do botão da lateral espelhado — mesma caixa de 26×24, mesma
    /// borda, mesma sombra —, com a barra cheia do lado direito porque é do lado
    /// direito que a trilha vive.
    private var agendaToggle: some View {
        Button(action: onToggleAgenda) {
            HStack(spacing: 2.5) {
                RoundedRectangle(cornerRadius: 1)
                    .strokeBorder(theme.ink4.color, lineWidth: 0.5)
                    .frame(width: 7, height: 11)
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.ink3.color)
                    .frame(width: 3, height: 11)
            }
            .frame(width: 26, height: 24)
            .background(theme.btn.color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(agendaHovering ? theme.accent.color : theme.btnLine.color, lineWidth: 0.5)
            }
            .shadow(theme.btnShadow)
        }
        .buttonStyle(.plain)
        .onHover { agendaHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: agendaHovering)
        .accessibilityLabel("Mostrar ou esconder a trilha da agenda")
    }

    private var workspaceTabs: some View {
        HStack(spacing: 2) {
            ForEach(Workspace.allCases, id: \.self) { tab in
                let active = tab == workspace
                Button { workspace = tab } label: {
                    Text(tab.label)
                        .font(theme.sans.font(size: 12.5, weight: .semibold))
                        .foregroundStyle((active ? theme.ink : theme.ink3).color)
                        .padding(.horizontal, 13)
                        .frame(height: 24)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: Self.tabCornerRadius(for: theme))
                                    .fill(theme.surface.color)
                                    // Sombra literal do protótipo (`0 1px 2px rgba(0,0,0,0.08)`), não um token do tema.
                                    // SwiftUI usa metade do blur do CSS — mesma conversão de ShadowToken.radius — então blur 2px vira radius 1.
                                    .shadow(color: .black.opacity(0.08), radius: 1, x: 0, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(theme.surface3.color)
        .clipShape(RoundedRectangle(cornerRadius: Self.tabCornerRadius(for: theme)))
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
            Text("⌘K")
                .font(theme.mono.font(size: 10))
                .foregroundStyle(theme.ink4.color)
        }
        .padding(.horizontal, 10)
        // Era `.frame(width: 400)`. Uma largura cravada aqui não encolhe: numa
        // janela estreita ela empurra as abas e o seletor de tema para fora da
        // barra. Como faixa, o campo é o primeiro a ceder — e em 1440 sobra
        // folga de sobra, então ele bate nos 400 do protótipo e não se move.
        .frame(minWidth: Self.searchMinimumWidth, maxWidth: Self.searchIdealWidth)
        .frame(height: 28)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line.color, lineWidth: 0.5)
        }
    }
}

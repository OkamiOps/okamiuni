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

public struct WindowChrome: View {
    public static let height: CGFloat = 58
    /// Espaço à esquerda para os semáforos da janela, que continuam nativos.
    public static let trafficLightInset: CGFloat = 78

    /// O protótipo diz "Buscar nas 4 caixas…" porque tinha quatro contas.
    /// Como a quantidade é do usuário, o texto concorda com ela.
    public static func searchPlaceholder(_ accountCount: Int) -> String {
        switch accountCount {
        case 0: "Buscar"
        case 1: "Buscar na caixa…"
        default: "Buscar nas \(accountCount) caixas…"
        }
    }

    @Environment(\.theme) private var theme
    @Binding var workspace: Workspace
    @Binding var query: String
    let accountCount: Int
    let onToggleSidebar: () -> Void

    public init(
        workspace: Binding<Workspace>,
        query: Binding<String>,
        accountCount: Int,
        onToggleSidebar: @escaping () -> Void
    ) {
        self._workspace = workspace
        self._query = query
        self.accountCount = accountCount
        self.onToggleSidebar = onToggleSidebar
    }

    public var body: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: Self.trafficLightInset - 14, height: 1)

            sidebarToggle

            Image(theme.isDark ? "uni-lockup-dark" : "uni-lockup-light")
                .resizable()
                .scaledToFit()
                .frame(height: 38)
                .accessibilityLabel("OkamiUNI")

            workspaceTabs

            searchField
                .frame(maxWidth: .infinity)

            // O seletor de temas entra aqui na Task 6. Até lá, um vazio do
            // tamanho do botão para o espaçamento da barra já ficar certo.
            Color.clear.frame(width: 96, height: 26)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.height)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .bottom)
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
                    .strokeBorder(theme.btnLine.color, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mostrar ou esconder a barra lateral")
    }

    private var workspaceTabs: some View {
        HStack(spacing: 2) {
            ForEach(Workspace.allCases, id: \.self) { tab in
                let active = tab == workspace
                Button { workspace = tab } label: {
                    Text(tab.label)
                        .font(theme.sans.font(size: 12, weight: active ? .semibold : .regular))
                        .foregroundStyle((active ? theme.ink : theme.ink3).color)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: theme.radiusSmall - 2)
                                    .fill(theme.surface.color)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(theme.surface3.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
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
        .frame(width: 400, height: 28)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line.color, lineWidth: 0.5)
        }
    }
}

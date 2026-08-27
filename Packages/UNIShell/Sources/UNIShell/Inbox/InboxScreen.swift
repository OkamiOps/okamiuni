import SwiftUI
import UNIDesign
import UNICore

public struct InboxScreen: View {
    @Environment(\.theme) private var theme
    @State private var sidebarExpanded = true
    @State private var workspace: Workspace = .mail
    @State private var query = ""
    let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Barra do topo (58px)
            WindowChrome(
                workspace: $workspace,
                query: $query,
                accountCount: store.accounts.count,
                onToggleSidebar: toggleSidebar
            )

            // Conteúdo principal
            switch workspace {
            case .mail:
                mailContent
            case .calendar:
                calendarContent
            }
        }
        .task {
            await store.load()
        }
        .onChange(of: query) { _, newQuery in
            store.query = newQuery
        }
    }

    private var mailContent: some View {
        HStack(spacing: 0) {
            // Barra lateral (expandida ou recolhida)
            if sidebarExpanded {
                FolderSidebar(store: store)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                SidebarRail(store: store)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // Lista de mensagens
            MessageList(store: store)

            // Painel de leitura
            ReaderPane(store: store, onAddEvent: { _ in })

            // Trilha de agenda
            // Ambos (data e minuto) vêm de Fixtures para coerência durante testes
            // nowMinute é constante e não depende do fuso da máquina
            AgendaRail(
                store: store,
                now: Fixtures.nowMinute,
                headerDate: Fixtures.today
            )
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var calendarContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agenda semanal")
                .font(theme.sans.font(size: 13, weight: .medium))
                .foregroundStyle(theme.ink.color)
            Text("Previsto para Marco 4")
                .font(theme.sans.font(size: 11))
                .foregroundStyle(theme.ink4.color)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surface.color)
    }

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.18)) {
            sidebarExpanded.toggle()
        }
    }
}

// MARK: - Placeholders

private struct ReaderPlaceholder: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Leitura da mensagem")
                .font(theme.sans.font(size: 13, weight: .medium))
                .foregroundStyle(theme.ink.color)
            Text("Clique em uma mensagem para ler")
                .font(theme.sans.font(size: 11))
                .foregroundStyle(theme.ink4.color)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surface.color)
        .hairline(theme.line, edges: .trailing)
    }
}

private struct AgendaPlaceholder: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agenda do dia")
                .font(theme.sans.font(size: 13, weight: .medium))
                .foregroundStyle(theme.ink.color)
            Text("Previsto para Marco 4")
                .font(theme.sans.font(size: 11))
                .foregroundStyle(theme.ink4.color)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 262)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .leading)
    }
}

#if os(macOS)
#Preview {
    InboxScreen(store: MailStore(source: InMemoryMailSource.fixtures))
        .environment(ThemeStore())
        .frame(width: 1440, height: 916)
}
#endif

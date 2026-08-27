import SwiftUI
import UNIDesign
import UNICore

public struct InboxScreen: View {
    @Environment(\.theme) private var theme

    // Intenção do usuário, não resultado. Quem decide o que aparece é
    // `PaneLayout`, cruzando isto com a largura que a janela tem agora. Guardar
    // a intenção separada do resultado é o que faz a lateral voltar sozinha
    // quando a janela cresce de novo.
    @State private var wantsSidebar = true
    @State private var wantsAgenda = true

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
                onToggleSidebar: toggleSidebar,
                onToggleAgenda: toggleAgenda
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

    /// O `GeometryReader` existe por um motivo só: dar a largura real da janela
    /// a `PaneLayout`. A decisão em si não mora aqui — este `View` é `@MainActor`
    /// e a aritmética precisa ser chamável de teste nonisolated.
    private var mailContent: some View {
        GeometryReader { proxy in
            let layout = PaneLayout.resolve(
                width: proxy.size.width,
                wantsSidebar: wantsSidebar,
                wantsAgenda: wantsAgenda
            )

            HStack(spacing: 0) {
                // Barra lateral. Ela nunca some por completo: recolhida, é a
                // trilha de 62pt da Task 7B.
                if layout.sidebarExpanded {
                    FolderSidebar(store: store, width: layout.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    SidebarRail(store: store, width: layout.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                // Lista de mensagens — o único painel cuja largura de fato varia.
                MessageList(store: store, width: layout.messageListWidth)

                // Painel de leitura: fica com tudo o que sobrar.
                ReaderPane(store: store, onAddEvent: { _ in })

                // Trilha de agenda — o primeiro painel a sair quando aperta.
                // Ambos (data e minuto) vêm de Fixtures para coerência durante testes
                // nowMinute é constante e não depende do fuso da máquina
                if layout.agendaVisible {
                    AgendaRail(
                        store: store,
                        now: Fixtures.nowMinute,
                        headerDate: Fixtures.today,
                        width: PaneLayout.agendaWidth
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            // Só as duas decisões discretas animam. Animar `messageListWidth`
            // junto faria a lista arrastar atrás do cursor durante o
            // redimensionamento, com 0.18s de atraso a cada quadro.
            .animation(Self.paneTransition, value: layout.sidebarExpanded)
            .animation(Self.paneTransition, value: layout.agendaVisible)
        }
    }

    /// A mesma curva do toggle manual, para recolher por arraste e por clique
    /// parecerem a mesma coisa.
    private static let paneTransition: Animation = .easeInOut(duration: 0.18)

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
        withAnimation(Self.paneTransition) {
            wantsSidebar.toggle()
        }
    }

    private func toggleAgenda() {
        withAnimation(Self.paneTransition) {
            wantsAgenda.toggle()
        }
    }
}

#if os(macOS)
#Preview {
    InboxScreen(store: MailStore(source: InMemoryMailSource.fixtures))
        .environment(ThemeStore())
        .frame(width: 1440, height: 916)
}
#endif

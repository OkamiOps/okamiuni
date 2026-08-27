import SwiftUI
import UNIDesign
import UNICore

public struct InboxScreen: View {
    @Environment(\.theme) private var theme
    /// As quatro janelas da Task U são cenas de verdade, abertas por aqui.
    @Environment(\.openWindow) private var openWindow

    // Intenção do usuário, não resultado. Quem decide o que aparece é
    // `PaneLayout`, cruzando isto com a largura que a janela tem agora. Guardar
    // a intenção separada do resultado é o que faz a lateral voltar sozinha
    // quando a janela cresce de novo.
    @State private var wantsSidebar = true
    @State private var wantsAgenda = true

    /// A terceira e a quarta intenções, e as únicas que sobrevivem ao
    /// encerramento do app. Como `wantsSidebar`, elas entram na `PaneLayout` e
    /// saem de lá recortadas pelo que a janela comporta.
    @State private var paneWidths = PaneWidthStore()

    /// Largura que o painel tinha quando o gesto começou. O `DragGesture`
    /// reporta translação acumulada, não posição, então a soma precisa de uma
    /// origem fixa — sem ela, cada quadro somaria em cima do quadro anterior e
    /// a divisória dispararia para o fim da tela.
    @State private var listDragOrigin: CGFloat?
    @State private var agendaDragOrigin: CGFloat?

    /// O retorno com "Desfazer" das ações destrutivas, partilhado entre a
    /// lista, o leitor e a tecla ⌫ — ver `ActionReceipts`.
    @State private var receipts = ActionReceipts()

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
                onToggleAgenda: toggleAgenda,
                onCompose: openNewMessage
            )

            // Conteúdo principal
            switch workspace {
            case .mail:
                mailContent
            case .calendar:
                calendarContent
            }
        }
        // Os atalhos que agem sobre a mensagem selecionada. Por `background`
        // para não ocuparem lugar nenhum no layout — ver `MessageShortcuts`.
        .background(MessageShortcuts(store: store))
        .environment(receipts)
        .task {
            await store.load()
        }
        .onChange(of: query) { _, newQuery in
            store.query = newQuery
        }
        // Revelar uma mensagem pode vir de **fora** desta tela: o botão "Email"
        // da janela 04 é outra cena e só alcança o `MailStore`. `revealCount`
        // é o único caminho que ele tem até a aba, e sem a troca o clique
        // selecionaria uma mensagem numa lista que não está na tela.
        .onChange(of: store.revealCount) { _, _ in
            workspace = .mail
            query = store.query
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
                wantsAgenda: wantsAgenda,
                draggedListWidth: paneWidths.messageList,
                draggedAgendaWidth: paneWidths.agenda
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
                MessageList(
                    store: store,
                    width: layout.messageListWidth,
                    onOpenWindow: openMessageWindow
                )

                // Painel de leitura: fica com tudo o que sobrar.
                ReaderPane(store: store, onReply: openComposer)

                // Trilha de agenda — o primeiro painel a sair quando aperta.
                // Ambos (data e minuto) vêm de Fixtures para coerência durante testes
                // nowMinute é constante e não depende do fuso da máquina
                if layout.agendaVisible {
                    AgendaRail(
                        store: store,
                        now: Fixtures.nowMinute,
                        headerDate: Fixtures.today,
                        width: layout.agendaRailWidth,
                        onOpenEvent: openEventWindow,
                        onRevealMessage: reveal
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
            // As divisórias vêm por cima, e não dentro do `HStack`: seis pontos
            // de alvo entre a lista e o leitor empurrariam a tela inteira em
            // seis pontos e desalinhariam o marco da Task P. Aqui elas custam
            // zero ao layout.
            .overlay(alignment: .topLeading) {
                dividers(layout: layout, windowWidth: proxy.size.width)
            }
            // O referencial em que o arraste é medido, e o motivo de ele vir
            // **depois** do `.overlay`: assim as divisórias são descendentes
            // dele. O retângulo que ele nomeia é o do conteúdo da janela, preso
            // ao `proxy` — o único ancestral por aqui que não se mexe enquanto a
            // divisória se mexe. Medir no espaço local da própria calha fazia a
            // divisória andar metade do cursor; ver `PaneDivider.coordinateSpace`.
            .coordinateSpace(.named(PaneDivider.coordinateSpace))
        }
    }

    // MARK: - As divisórias arrastáveis

    /// As duas calhas de arraste, posicionadas sobre as linhas que os painéis
    /// já desenham: lista ↔ leitor e leitor ↔ agenda.
    ///
    /// A da lateral fica de fora de propósito. A lateral não tem largura
    /// contínua: ela é aberta (236) ou trilha (62), duas medidas canônicas que
    /// a `SidebarRail` e a `FolderSidebar` usam para escolher o que desenham em
    /// cada uma. Torná-la arrastável não é acrescentar um alvo, é trocar o
    /// modelo dela — e o botão da barra do topo já faz o que ela precisa.
    @ViewBuilder
    private func dividers(layout: PaneLayout, windowWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            divider(
                at: layout.messageListTrailingEdge,
                onDrag: { translation in
                    let origin = listDragOrigin ?? layout.messageListWidth
                    listDragOrigin = origin
                    // Puxar para a direita alarga a lista.
                    paneWidths.setMessageList(origin + translation)
                },
                onEnd: { listDragOrigin = nil },
                onReset: {
                    withAnimation(Self.paneTransition) { paneWidths.resetMessageList() }
                }
            )

            if layout.agendaVisible {
                divider(
                    at: layout.agendaLeadingEdge(inWindowOfWidth: windowWidth),
                    onDrag: { translation in
                        let origin = agendaDragOrigin ?? layout.agendaRailWidth
                        agendaDragOrigin = origin
                        // A agenda cresce para a esquerda: puxar para a direita
                        // a estreita.
                        paneWidths.setAgenda(origin - translation)
                    },
                    onEnd: { agendaDragOrigin = nil },
                    onReset: {
                        withAnimation(Self.paneTransition) { paneWidths.resetAgenda() }
                    }
                )
            }
        }
    }

    /// Centra o alvo de 6pt sobre a linha em `x`, para o ponteiro poder chegar
    /// pelos dois lados.
    private func divider(
        at x: CGFloat,
        onDrag: @escaping (CGFloat) -> Void,
        onEnd: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        PaneDivider(onDrag: onDrag, onEnd: onEnd, onReset: onReset)
            .offset(x: PaneDivider.leadingEdge(centeredOn: x))
    }

    /// A mesma curva do toggle manual, para recolher por arraste e por clique
    /// parecerem a mesma coisa.
    private static let paneTransition: Animation = .easeInOut(duration: 0.18)

    /// A aba Agenda leva a **mesma** barra lateral do email, porque no
    /// protótipo ela é do shell e não da tela do email — ver `CalendarScreen`.
    /// Por isso `wantsSidebar` atravessa daqui: é a intenção que o botão da
    /// barra do topo mexe, e ela tem de valer nas duas abas.
    private var calendarContent: some View {
        CalendarScreen(
            store: store,
            now: Fixtures.nowMinute,
            anchor: Fixtures.today,
            wantsSidebar: wantsSidebar,
            onOpenEvent: openEventWindow,
            onRevealMessage: reveal
        )
    }

    // MARK: - Janelas

    /// 03 Composer. Gancho do "Responder" no leitor.
    private func openComposer(_ message: Message) {
        openWindow(id: UNIWindow.composer, value: message.id)
    }

    /// 05 Email em janela. Gancho do duplo clique na lista.
    private func openMessageWindow(_ message: Message) {
        openWindow(id: UNIWindow.message, value: message.id)
    }

    /// 04 Detalhe do compromisso. Gancho do clique na trilha de agenda.
    private func openEventWindow(_ item: AgendaItem) {
        openWindow(id: UNIWindow.event, value: item.id)
    }

    /// "Ir para o email de origem", do menu de contexto de um compromisso.
    ///
    /// Precisa trocar de aba, e é por isso que ele mora aqui e não no menu:
    /// `workspace` é estado desta tela. Sem a troca, o item clicado da aba
    /// Agenda selecionaria a mensagem numa lista que não está na tela — a
    /// definição de botão mudo.
    private func reveal(_ messageID: String) {
        workspace = .mail
        store.reveal(messageID)
        // O campo de busca é `@State` daqui e o `MailStore` é a outra ponta do
        // mesmo valor. `reveal` pode ter limpado a busca do lado de lá; sem
        // esta linha o campo continuaria escrito com o termo que já não filtra
        // nada.
        query = store.query
    }

    /// 06 Nova mensagem. Chega por ⌘N (menu do app) e, quando a barra do topo
    /// ganhar o botão "Escrever", por ele — é este o fechamento que o
    /// `WindowChrome` precisa receber.
    public func openNewMessage() {
        openWindow(id: UNIWindow.newMessage, value: store.selectedAccountID ?? "")
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

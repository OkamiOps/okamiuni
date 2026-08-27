import SwiftUI
import UNIDesign
import UNICore

/// A aba **Agenda** inteira: barra lateral, cabeçalho e a visão escolhida.
///
/// ## Por que a barra lateral está aqui
///
/// No protótipo ela **não** pertence à tela do email. Ela é do shell: fica
/// fora do `sc-if` que separa "01 Caixa unificada" de "02 Agenda semanal"
/// (linhas 1013–1058, contra os gates nas 1059 e 1393). Medido no navegador
/// com a aba Agenda no ar, as seções "Fluxo" e "Caixas" continuam desenhadas,
/// em 237px, e a tela da agenda começa depois delas.
///
/// A aba Agenda subia sem ela porque a `InboxScreen` monta a lateral dentro do
/// ramo do email. Isso é o que o dono do projeto viu: "agenda não aparece a
/// barra lateral, eu podia selecionar a agenda, tinha filtros".
///
/// ## O que a lateral faz aqui, e o que não faz
///
/// Ela é a mesma `FolderSidebar`/`SidebarRail` do email, com o mesmo estado:
/// as caixas de "Fluxo" e a seleção de conta em "Caixas". **A seleção de conta
/// não filtra a grade da agenda**, e isso é o protótipo, não esquecimento: lá,
/// `st.account` entra em `visible()` — a lista de mensagens — e as três visões
/// da agenda saem de `WEEK`/`MONTH`, que nunca consultam a conta selecionada.
/// Inventar o filtro aqui seria inventar comportamento que o desenho não tem.
/// Ele está registrado no relatório da tarefa como pergunta em aberto.
public struct CalendarScreen: View {

    @Environment(\.theme) private var theme

    let store: MailStore
    /// Minutos desde a meia-noite. Injetado para o teste não depender do relógio.
    let now: Int
    /// O "hoje" do app: de onde saem os números dos dias e o `dayOffset` 0.
    let anchor: Date
    /// A **intenção** do usuário quanto à lateral, vinda do botão da barra do
    /// topo. O que aparece é isto cruzado com a largura da janela — a mesma
    /// regra do email, em `PaneLayout.sidebarExpanded(width:wantsSidebar:)`.
    let wantsSidebar: Bool
    let onOpenEvent: (AgendaItem) -> Void

    /// Qual visão está no ar. Protótipo: `st.calView`, que abre em `'semana'`.
    @State private var mode: CalendarViewMode = .week
    /// Qual dia a visão Dia mostra, em dias a partir de `anchor`.
    /// Protótipo: `st.dayW`/`st.dayD`, que abrem na célula de hoje.
    @State private var selectedDayOffset = 0
    /// Protótipo: `st.picker`.
    @State private var pickerOpen = false

    public init(
        store: MailStore,
        now: Int,
        anchor: Date,
        wantsSidebar: Bool = true,
        onOpenEvent: @escaping (AgendaItem) -> Void = { _ in }
    ) {
        self.init(
            store: store, now: now, anchor: anchor, wantsSidebar: wantsSidebar,
            initialMode: .week, initialPickerOpen: false, onOpenEvent: onOpenEvent
        )
    }

    /// A mesma tela com o estado inicial forçado. **Só para verificação fora
    /// da tela.**
    ///
    /// O harness de renderização não clica em nada — é essa a regra do
    /// projeto, e é por isso que ele não rouba a máquina de quem está
    /// trabalhando. Sem um caminho como este, a visão Dia, a visão Mês e o
    /// seletor de data aberto seriam estados que nenhum PNG jamais mostraria,
    /// e "não reproduzi no harness" viraria evidência de nada. Mesmo padrão do
    /// `debugOpenPanel` das janelas.
    init(
        store: MailStore,
        now: Int,
        anchor: Date,
        wantsSidebar: Bool = true,
        initialMode: CalendarViewMode,
        initialPickerOpen: Bool = false,
        onOpenEvent: @escaping (AgendaItem) -> Void = { _ in }
    ) {
        self.store = store
        self.now = now
        self.anchor = anchor
        self.wantsSidebar = wantsSidebar
        self.onOpenEvent = onOpenEvent
        _mode = State(initialValue: initialMode)
        _pickerOpen = State(initialValue: initialPickerOpen)
    }

    public var body: some View {
        GeometryReader { proxy in
            let expanded = PaneLayout.sidebarExpanded(
                width: proxy.size.width, wantsSidebar: wantsSidebar
            )
            let sidebarWidth = PaneLayout.sidebarWidth(
                width: proxy.size.width, wantsSidebar: wantsSidebar
            )

            HStack(spacing: 0) {
                if expanded {
                    FolderSidebar(store: store, width: sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    SidebarRail(store: store, width: sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                calendarColumn
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.18), value: expanded)
        }
    }

    private var calendarColumn: some View {
        VStack(spacing: 0) {
            CalendarHeader(
                store: store,
                anchor: anchor,
                mode: mode,
                selectedDayOffset: selectedDayOffset,
                pickerOpen: pickerOpen,
                onPick: pick(_:),
                onStepDay: step(_:),
                onGoToday: goToday,
                onTogglePicker: { pickerOpen.toggle() },
                onPickDay: pickDay(_:)
            )
            // A faixa vem por cima da grade: o seletor de data é desenhado
            // dentro dela e passa 231pt abaixo do seu limite. Sem o `zIndex`,
            // o `VStack` empilha o irmão seguinte por cima e o popover fica
            // metade escondido atrás da grade.
            .zIndex(30)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surface.color)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .day:
            DayScreen(
                store: store, now: now, anchor: anchor,
                dayOffset: selectedDayOffset, onOpenEvent: onOpenEvent
            )
        case .week:
            WeekScreen(
                store: store, now: now, anchor: anchor,
                focusOffset: selectedDayOffset, onOpenEvent: onOpenEvent
            )
        case .month:
            MonthScreen(
                store: store, anchor: anchor, focusOffset: selectedDayOffset,
                onOpenEvent: onOpenEvent,
                onOpenDay: { offset in
                    selectedDayOffset = offset
                    mode = .day
                }
            )
        }
    }

    // MARK: - Estado

    /// Trocar de aba fecha o seletor. Protótipo: só `stepDay`, `goToday` e a
    /// escolha de um dia o fecham — mas ele nem chega a ficar aberto fora da
    /// visão Dia, porque o `sc-if` que o desenha some junto. Fechar aqui é o
    /// equivalente: sem isso, sair para Mês e voltar para Dia o traria aberto.
    private func pick(_ candidate: CalendarViewMode) {
        mode = candidate
        pickerOpen = false
    }

    /// O passo de navegação, no tamanho da visão: um dia, uma semana, um mês.
    ///
    /// Antes só a visão Dia tinha `‹ ›`, e ela andava travada nas pontas da
    /// grade do mês, como o protótipo faz. O dono cobrou o óbvio: semana e mês
    /// também se navegam. Travar nas pontas deixou de fazer sentido quando o
    /// mês passou a poder virar — agora o foco anda livre.
    private func step(_ direction: Int) {
        selectedDayOffset = MonthAgenda.navigationStep(
            days: mode.navigationScope, from: selectedDayOffset,
            anchor: anchor, direction: direction
        )
        pickerOpen = false
    }

    /// Protótipo: `goToday` volta para a célula de hoje, que é `dayOffset` 0.
    private func goToday() {
        selectedDayOffset = 0
        pickerOpen = false
    }

    private func pickDay(_ offset: Int) {
        selectedDayOffset = offset
        pickerOpen = false
    }
}

#if os(macOS)
#Preview {
    let store = MailStore(source: InMemoryMailSource.fixtures)
    return CalendarScreen(store: store, now: Fixtures.nowMinute, anchor: Fixtures.today)
        .environment(ThemeStore())
        .frame(width: 1440, height: 858)
        .task { await store.load() }
}
#endif

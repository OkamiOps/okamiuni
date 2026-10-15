import SwiftUI
import UNIDesign
import UNICore

/// A aba **Agenda** inteira: barra lateral, cabeçalho e a visão escolhida.
///
/// ## Por que a barra lateral está aqui
///
/// No protótipo ela **não** pertence à tela do email. Ela é do shell: fica
/// fora do `sc-if` que separa "01 Caixa unificada" de "02 Agenda semanal".
/// A aba Agenda subia sem ela porque a `InboxScreen` montava a lateral só no
/// ramo do email.
///
/// ## O que a lateral faz aqui
///
/// `CalendarSidebar`: os calendários do macOS (Todoist, iCloud, Gmail,
/// inscritos), um interruptor por calendário. Não é a `FolderSidebar` do
/// email — filtrar a grade pela caixa de correio escondia o EventKit.
/// O estado da aba Agenda que o shell precisa dividir com a tela.
///
/// No shell Vidro a lateral da Agenda mora na **coluna de contexto**, que é
/// irmã do painel da grade e não filha dela: o mês miúdo escolhe o dia que a
/// grade desenha, e o "Novo compromisso" da coluna abre a folha que a tela
/// apresenta. Com o estado dentro da `CalendarScreen`, os dois lados ficariam
/// cada um com a sua cópia — clicar no dia 12 no mês miúdo não moveria a
/// grade. Quem não precisa dividir nada (previews, testes, a aba antiga)
/// deixa `nil` e a tela cria o seu.
@MainActor
@Observable
public final class CalendarShellState {
    public var mode: CalendarViewMode
    public var selectedDayOffset: Int
    public var creatingAppointment = false

    public init(mode: CalendarViewMode = .week, selectedDayOffset: Int = 0) {
        self.mode = mode
        self.selectedDayOffset = selectedDayOffset
    }
}

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
    let intelligencePresentation: IntelligencePresentation
    let onOpenAssistant: () -> Void
    let onCompose: (() -> Void)?
    let onOpenAccounts: (() -> Void)?
    let onOpenEvent: (AgendaItem) -> Void
    /// "Ir para o email de origem", do menu de contexto do cartão. Sai da aba
    /// Agenda: quem sabe voltar para o email é o `InboxScreen`.
    let onRevealMessage: (String) -> Void

    /// O estado que a tela divide com a coluna de contexto do shell. `nil`
    /// fora dele — e aí vale `ownState`.
    let shell: CalendarShellState?
    /// Desenha a própria lateral? No shell Vidro ela está na coluna de
    /// contexto, do outro lado do painel.
    let showsSidebar: Bool

    /// Presente só com a coluna de contexto recolhida: o `sidebar.left` que a
    /// traz de volta, na ponta esquerda do cabeçalho da Agenda. Fica fora dos
    /// `init` porque é do shell, não da tela — ver `expandingSidebar(_:)`.
    var onExpandSidebar: (() -> Void)?

    /// Liga o botão de mostrar a lateral no cabeçalho desta tela.
    func expandingSidebar(_ action: (() -> Void)?) -> Self {
        var copia = self
        copia.onExpandSidebar = action
        return copia
    }

    /// Qual visão está no ar e qual dia a visão Dia mostra. Protótipo:
    /// `st.calView` (abre em `'semana'`) e `st.dayW`/`st.dayD` (abrem em hoje).
    @State private var ownState: CalendarShellState
    /// Protótipo: `st.picker`.
    @State private var pickerOpen = false

    private var state: CalendarShellState { shell ?? ownState }
    private var mode: CalendarViewMode { state.mode }
    private var selectedDayOffset: Int { state.selectedDayOffset }

    public init(
        store: MailStore,
        now: Int,
        anchor: Date,
        wantsSidebar: Bool = true,
        intelligencePresentation: IntelligencePresentation = .onThisMac,
        onOpenAssistant: @escaping () -> Void = {},
        onCompose: (() -> Void)? = nil,
        onOpenAccounts: (() -> Void)? = nil,
        onOpenEvent: @escaping (AgendaItem) -> Void = { _ in },
        onRevealMessage: @escaping (String) -> Void = { _ in },
        shell: CalendarShellState? = nil,
        showsSidebar: Bool = true
    ) {
        self.init(
            store: store, now: now, anchor: anchor, wantsSidebar: wantsSidebar,
            intelligencePresentation: intelligencePresentation,
            initialMode: .week, initialPickerOpen: false,
            onOpenAssistant: onOpenAssistant, onCompose: onCompose,
            onOpenAccounts: onOpenAccounts, onOpenEvent: onOpenEvent,
            onRevealMessage: onRevealMessage,
            shell: shell, showsSidebar: showsSidebar
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
        intelligencePresentation: IntelligencePresentation = .onThisMac,
        initialMode: CalendarViewMode,
        initialPickerOpen: Bool = false,
        onOpenAssistant: @escaping () -> Void = {},
        onCompose: (() -> Void)? = nil,
        onOpenAccounts: (() -> Void)? = nil,
        onOpenEvent: @escaping (AgendaItem) -> Void = { _ in },
        onRevealMessage: @escaping (String) -> Void = { _ in },
        shell: CalendarShellState? = nil,
        showsSidebar: Bool = true
    ) {
        self.store = store
        self.now = now
        self.anchor = anchor
        self.wantsSidebar = wantsSidebar
        self.intelligencePresentation = intelligencePresentation
        self.onOpenAssistant = onOpenAssistant
        self.onCompose = onCompose
        self.onOpenAccounts = onOpenAccounts
        self.onOpenEvent = onOpenEvent
        self.onRevealMessage = onRevealMessage
        self.shell = shell
        self.showsSidebar = showsSidebar
        _ownState = State(initialValue: CalendarShellState(mode: initialMode))
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
                if showsSidebar {
                    CalendarSidebar(
                        store: store,
                        width: sidebarWidth,
                        intelligencePresentation: intelligencePresentation,
                        onOpenAssistant: onOpenAssistant,
                        onCreate: { state.creatingAppointment = true },
                        onOpenAccounts: onOpenAccounts,
                        anchor: anchor,
                        selectedDayOffset: selectedDayOffset,
                        onPickDay: pickDay(_:)
                    )
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                // A faixa de retorno pende da coluna da agenda, e não da
                // tela inteira: a barra lateral tem o menu de caixa dela e
                // não produz recibo nenhum.
                calendarColumn.agendaUndoBand(store: store)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.18), value: expanded)
        }
        // Folha que **pende do topo**, e não `.sheet` centrada: o desenho dos
        // modais põe a folha a 56pt do topo da janela, com a Agenda visível
        // atrás dela e o véu por cima. É o que liga a folha ao lugar de onde
        // ela veio — ver `TopHangingSheet`.
        .topHangingSheet(
            isPresented: state.creatingAppointment,
            onDismiss: { state.creatingAppointment = false }
        ) {
            NewAppointmentSheet(
                store: store,
                anchor: anchor,
                initialDayOffset: selectedDayOffset,
                onClose: { state.creatingAppointment = false }
            )
        }
    }

    /// Os blocos que a IA propõe para hoje.
    ///
    /// É o mesmo `PlanoDoDia` do Painel, com as promessas que vencem hoje: a
    /// Agenda e o Painel não podem discordar sobre o que está proposto. O
    /// bloco de respostas fica de fora porque ele é do recorte da Caixa, que a
    /// Agenda não tem — e por isso a frase do topo conta o que ela de fato
    /// desenha na grade.
    private var propostos: [PlanoDoDia.Bloco] {
        let calendario = Calendar.current
        let promessas = store.visiblePendingItems.compactMap { item -> PlanoDoDia.Promessa? in
            guard let vence = item.dueDate,
                  calendario.isDate(vence, inSameDayAs: anchor) else { return nil }
            let partes = calendario.dateComponents([.hour, .minute], from: vence)
            return PlanoDoDia.Promessa(
                id: item.id,
                title: PainelDoDiaModelo.titulo(de: item.text),
                dueMinute: (partes.hour ?? 0) * 60 + (partes.minute ?? 0)
            )
        }
        guard !promessas.isEmpty else { return [] }
        return PlanoDoDia.make(
            agenda: store.visibleAgenda, replyBlock: nil, replyTitle: "",
            promessas: promessas, prazos: [], now: anchor, nowMinute: now
        )
        .filter { $0.tipo == .proposto }
    }

    private var calendarColumn: some View {
        let propostos = propostos
        return VStack(spacing: 0) {
            VidroAgendaCabecalho(
                store: store,
                anchor: anchor,
                mode: mode,
                selectedDayOffset: selectedDayOffset,
                pickerOpen: pickerOpen,
                blocosPropostos: propostos.count,
                onPick: pick(_:),
                onStepDay: step(_:),
                onGoToday: goToday,
                onTogglePicker: { pickerOpen.toggle() },
                onPickDay: pickDay(_:),
                onExpandSidebar: onExpandSidebar
            )
            // A faixa vem por cima da grade: o seletor de data é desenhado
            // dentro dela e passa 231pt abaixo do seu limite. Sem o `zIndex`,
            // o `VStack` empilha o irmão seguinte por cima e o popover fica
            // metade escondido atrás da grade.
            .zIndex(30)

            if let state = store.calendarAvailability {
                CalendarStatusBand(state: state) {
                    Task { await store.refreshCalendar(requestAuthorization: true) }
                }
            }

            content(propostos: propostos)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Quem pinta o fundo é o painel: uma segunda camada de `surface` por
        // cima dele apagava o vidro e desencontrava o tom nos opacos.
    }

    @ViewBuilder
    private func content(propostos: [PlanoDoDia.Bloco]) -> some View {
        switch mode {
        case .day:
            DayScreen(
                store: store, now: now, anchor: anchor,
                dayOffset: selectedDayOffset, onOpenEvent: onOpenEvent,
                onRevealMessage: onRevealMessage
            )
        case .week:
            WeekScreen(
                store: store, now: now, anchor: anchor,
                focusOffset: selectedDayOffset, propostos: propostos,
                onOpenEvent: onOpenEvent,
                onRevealMessage: onRevealMessage
            )
        case .month:
            MonthScreen(
                store: store, anchor: anchor, focusOffset: selectedDayOffset,
                onOpenEvent: onOpenEvent,
                onOpenDay: { offset in
                    state.selectedDayOffset = offset
                    state.mode = .day
                },
                onRevealMessage: onRevealMessage
            )
        }
    }

    // MARK: - Estado

    /// Trocar de aba fecha o seletor. Protótipo: só `stepDay`, `goToday` e a
    /// escolha de um dia o fecham — mas ele nem chega a ficar aberto fora da
    /// visão Dia, porque o `sc-if` que o desenha some junto. Fechar aqui é o
    /// equivalente: sem isso, sair para Mês e voltar para Dia o traria aberto.
    private func pick(_ candidate: CalendarViewMode) {
        state.mode = candidate
        pickerOpen = false
    }

    /// O passo de navegação, no tamanho da visão: um dia, uma semana, um mês.
    ///
    /// Antes só a visão Dia tinha `‹ ›`, e ela andava travada nas pontas da
    /// grade do mês, como o protótipo faz. O dono cobrou o óbvio: semana e mês
    /// também se navegam. Travar nas pontas deixou de fazer sentido quando o
    /// mês passou a poder virar — agora o foco anda livre.
    private func step(_ direction: Int) {
        state.selectedDayOffset = MonthAgenda.navigationStep(
            days: mode.navigationScope, from: selectedDayOffset,
            anchor: anchor, direction: direction
        )
        pickerOpen = false
    }

    /// Protótipo: `goToday` volta para a célula de hoje, que é `dayOffset` 0.
    private func goToday() {
        state.selectedDayOffset = 0
        pickerOpen = false
    }

    private func pickDay(_ offset: Int) {
        state.selectedDayOffset = offset
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

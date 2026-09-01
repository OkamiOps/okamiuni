import SwiftUI
import UNIDesign
import UNICore

/// A faixa no topo da tela 02.
///
/// Ela é a **mesma** nas três visões: título, as três abas, o navegador e a
/// contagem. O "Novo compromisso" mora só na lateral — dois botões na mesma
/// faixa repetiam a ação e brigavam com o navegador.
struct CalendarHeader: View {

    static let height: CGFloat = 52
    static let controlHeight: CGFloat = 32

    @Environment(\.theme) private var theme

    let store: MailStore
    let anchor: Date
    let mode: CalendarViewMode
    let selectedDayOffset: Int
    let pickerOpen: Bool
    let onPick: (CalendarViewMode) -> Void
    let onStepDay: (Int) -> Void
    let onGoToday: () -> Void
    let onTogglePicker: () -> Void
    let onPickDay: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Largura reservada, e não largura medida: era daqui que vinha o
            // defeito dos "controles que andam". Ver `ReservedText`.
            ReservedText(
                text: title,
                groups: titleCandidates,
                font: theme.serif.font(size: 18, weight: .semibold),
                color: theme.ink.color
            )

            viewTabs
            dayNavigator

            Text(meta)
                .font(theme.mono.font(size: 10))
                .foregroundStyle(theme.ink4.color)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 0)

            accountLegend
        }
        .padding(.horizontal, 20)
        .frame(height: Self.height)
        .hairline(theme.line2, edges: .bottom)
    }

    /// Protótipo: `calTitle` (linha 2359). Na visão Dia é o dia por extenso; nas
    /// outras duas, o mês.
    private var title: String {
        mode == .day
            ? MonthAgenda.longDayTitle(dayOffset: selectedDayOffset, anchor: anchor)
            : WeekAgenda.monthTitle(for: focusedDate)
    }

    /// Todos os títulos que **esta** visão pode mostrar, em grupos — a régua
    /// da largura reservada ao título.
    ///
    /// Na Semana e no Mês são os doze meses do ano em foco; na visão Dia são
    /// os dois pedaços de que qualquer dia do ano é feito. Ver
    /// `CalendarTitleReserve`, que explica por que dois pedaços bastam.
    private var titleCandidates: [[String]] {
        guard mode == .day else {
            return [CalendarTitleReserve.monthTitles(inYearOf: focusedDate)]
        }
        let pedacos = CalendarTitleReserve.longDayTitlePieces(inYearOf: focusedDate)
        return [pedacos.prefixes, pedacos.suffixes]
    }

    /// O mesmo para o botão que abre o seletor: "ter, 25 ago" e "qua, 1 set"
    /// não medem igual, e o que estivesse à direita dele andava junto.
    private var dayLabelCandidates: [[String]] {
        let pedacos = CalendarTitleReserve.shortDayLabelPieces(inYearOf: focusedDate)
        return [pedacos.prefixes, pedacos.suffixes]
    }

    /// O dia em que a navegação está parada. Título, número da semana e
    /// contagem do mês saem daqui — antes saíam da âncora fixa, e por isso não
    /// mudavam ao navegar.
    private var focusedDate: Date {
        Calendar.current.date(byAdding: .day, value: selectedDayOffset, to: anchor) ?? anchor
    }

    /// Protótipo: `calMeta` (linha 2360).
    ///
    /// A contagem do mês é derivada, e não a literal `'12 compromissos'` que o
    /// protótipo escreve — ver `MonthAgenda.eventCount`.
    private var meta: String {
        switch mode {
        case .day:
            DayAgenda.blockCountLabel(
                WeekAgenda.items(on: selectedDayOffset, in: store.calendarAgenda).count
            )
        case .week:
            "semana \(WeekAgenda.weekNumber(for: focusedDate))"
        case .month:
            "\(MonthAgenda.eventCount(from: store.calendarAgenda, anchor: anchor, focusOffset: selectedDayOffset)) compromissos"
        }
    }

    // MARK: - As três abas

    /// As três, todas vivas. Elas nasceram com Dia e Mês desabilitadas porque
    /// as visões não existiam; existir e continuar apagada seria pior que o
    /// problema original.
    private var viewTabs: some View {
        HStack(spacing: 2) {
            ForEach(CalendarViewMode.allCases) { candidate in
                tab(candidate)
            }
        }
        .padding(3)
        .background(theme.surface3.color)
        .clipShape(Capsule())
    }

    private func tab(_ candidate: CalendarViewMode) -> some View {
        let isActive = candidate == mode
        return Button { onPick(candidate) } label: {
            Text(candidate.label)
                .font(theme.sans.font(size: 12.5, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? theme.ink.color : theme.ink3.color)
                .padding(.horizontal, 12)
                .frame(height: Self.controlHeight - 6)
                .background {
                    if isActive {
                        Capsule()
                            .fill(theme.surface.color)
                            .shadow(color: .black.opacity(0.08), radius: 1, x: 0, y: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusRing(in: Capsule())
        .accessibilityLabel(candidate.label)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: - O navegador de dia

    /// Quatro chips com borda — não uma cápsula cinza. A cápsula recortava o
    /// seletor (231pt dentro de 32pt) e o dono via um botão morto. O overlay
    /// mora neste `HStack`, **sem** `clipShape`, para pintar por cima do `›`
    /// e do Hoje e descer pela grade.
    private var dayNavigator: some View {
        HStack(spacing: 6) {
            stepButton(direction: -1, symbol: "chevron.left", label: previousLabel)
            datePickerButton
            stepButton(direction: 1, symbol: "chevron.right", label: nextLabel)
            todayButton
        }
        .overlay(alignment: .topLeading) {
            if pickerOpen {
                DatePickerPopover(
                    store: store, anchor: anchor,
                    selectedDayOffset: selectedDayOffset,
                    onPickDay: onPickDay
                )
                // Depois da seta esquerda (32) e do vão (6), alinhado ao chip
                // da data; 4pt abaixo do próprio chip.
                .offset(x: Self.controlHeight + 6, y: Self.controlHeight + 4)
            }
        }
    }

    private func stepButton(direction: Int, symbol: String, label: String) -> some View {
        CalendarButton(
            appearance: .quiet,
            width: Self.controlHeight,
            height: Self.controlHeight,
            horizontalPadding: 0,
            action: { onStepDay(direction) }
        ) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
        }
        .help(label)
        .accessibilityLabel(label)
    }

    private var datePickerButton: some View {
        CalendarButton(
            appearance: pickerOpen ? .active : .strong,
            height: Self.controlHeight,
            horizontalPadding: 11,
            action: onTogglePicker
        ) {
            HStack(spacing: 6) {
                ReservedText(
                    text: MonthAgenda.shortDayLabel(
                        dayOffset: selectedDayOffset, anchor: anchor
                    ),
                    groups: dayLabelCandidates,
                    font: theme.sans.font(size: 12.5, weight: .semibold),
                    color: nil
                )
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.7)
            }
        }
        .help("Escolher o dia")
        .accessibilityLabel("Escolher o dia")
    }

    private var todayButton: some View {
        CalendarButton(
            appearance: .quiet,
            height: Self.controlHeight,
            horizontalPadding: 12,
            action: onGoToday
        ) {
            Text("Hoje")
                .font(theme.sans.font(size: 12.5, weight: .semibold))
        }
        .disabled(selectedDayOffset == 0)
        .help("Ir para hoje")
        .accessibilityLabel("Ir para hoje")
    }

    private var previousLabel: String {
        switch mode {
        case .day: "Dia anterior"
        case .week: "Semana anterior"
        case .month: "Mês anterior"
        }
    }

    private var nextLabel: String {
        switch mode {
        case .day: "Próximo dia"
        case .week: "Próxima semana"
        case .month: "Próximo mês"
        }
    }

    // MARK: - Legenda de contas

    /// Uma entrada por conta, sem teto: a quantidade é do usuário, e qualquer
    /// provedor em qualquer domínio entra aqui do mesmo jeito.
    ///
    /// **É legenda, não filtro.** No protótipo estas entradas não têm `onClick`
    /// (linhas 1432–1436) — a seleção de conta mora na barra lateral, que a
    /// aba Agenda também mostra. Dar clique aqui inventaria um segundo lugar
    /// para a mesma decisão.
    private var accountLegend: some View {
        HStack(spacing: 14) {
            ForEach(store.accounts) { account in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(CalendarTint.color(of: account.id, in: store, theme: theme))
                        .frame(width: 7, height: 7)
                    Text(account.host)
                        .font(theme.sans.font(size: 11.5))
                        .foregroundStyle(theme.ink2.color)
                        .lineLimit(1)
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Cor da caixa \(account.host)")
            }
        }
    }
}

/// Um texto que ocupa sempre a largura do **maior** texto que aquele lugar
/// pode mostrar.
///
/// É o conserto do defeito dos controles que andam: a faixa da agenda é um
/// `HStack`, e num `HStack` quem está à direita começa onde o vizinho da
/// esquerda termina. Com o título medindo o que a data medisse, ir de "Julho
/// 2026" para "Agosto 2026" deslocava as abas, o `‹ ›`, o "Hoje" e a contagem —
/// e o dono, que navega com cliques repetidos em `›`, via o botão fugir do
/// cursor. O mesmo valia para o botão "ter, 25 ago".
///
/// A reserva é feita **desenhando**, e não com uma constante em pontos: a
/// largura depende da fonte que a máquina de fato tem (a Newsreader do desenho
/// pode não estar instalada, e aí vale a do sistema), e uma constante escolhida
/// numa máquina mentiria na outra. Os candidatos vêm escondidos — ocupam
/// layout, não pintam pixel — e a soma dos maiores de cada grupo é a largura da
/// fatia.
///
/// Se algum texto passar da reserva, ele **cresce** em vez de ser cortado ou de
/// pintar por cima das abas: a pior consequência possível de um candidato mal
/// escolhido é o defeito antigo naquele caso, nunca um título ilegível.
private struct ReservedText: View {
    let text: String
    /// Grupos de candidatos. A reserva é a soma do maior de cada grupo — ver
    /// `CalendarTitleReserve` para o porquê de haver mais de um.
    let groups: [[String]]
    let font: Font
    /// `nil` herda a cor de quem contém, que é o caso do rótulo dentro do
    /// botão do seletor: ele muda de cor com o estado do botão.
    let color: Color?

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, grupo in
                    ZStack(alignment: .leading) {
                        ForEach(grupo, id: \.self) { candidato in
                            Text(candidato).font(font).lineLimit(1).fixedSize()
                        }
                    }
                }
            }
            .hidden()
            .accessibilityHidden(true)

            visivel
        }
        .fixedSize()
    }

    /// A cor só é aplicada quando há uma: dentro do botão do seletor, o rótulo
    /// herda a cor do botão, e cravar `.primary` aqui apagaria o realce dele.
    @ViewBuilder
    private var visivel: some View {
        let base = Text(text).font(font).lineLimit(1).fixedSize()
        if let color {
            base.foregroundStyle(color)
        } else {
            base
        }
    }
}

/// A cor do compromisso nas quatro visões — a mesma da bolinha na lateral.
///
/// Pintar pela caixa de email (ou pelo acento do tema) fazia o bloco nascer
/// numa cor que nenhuma agenda listada tem. O calendário da lateral manda.
enum CalendarTint {
    @MainActor
    static func token(of item: AgendaItem, in store: MailStore, theme: Theme) -> TokenColor? {
        if let hex = store.calendarSwatchHex(for: item), let token = TokenColor(css: hex) {
            return token
        }
        return store.account(item.accountID).flatMap {
            TokenColor(css: $0.tint(isDark: theme.isDark))
        }
    }

    @MainActor
    static func color(of item: AgendaItem, in store: MailStore, theme: Theme) -> Color {
        token(of: item, in: store, theme: theme)?.color
            ?? color(of: item.accountID, in: store, theme: theme)
    }

    @MainActor
    static func color(of accountID: String, in store: MailStore, theme: Theme) -> Color {
        store.account(accountID)
            .flatMap { TokenColor(css: $0.tint(isDark: theme.isDark))?.color }
            ?? theme.accent.color
    }
}

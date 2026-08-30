import SwiftUI
import UNIDesign
import UNICore

/// A faixa de 46pt no topo da tela 02 (protótipo, linhas 1395–1438).
///
/// Ela é a **mesma** nas três visões: título, as três abas, o navegador de dia
/// (só na visão Dia), a contagem e a legenda de contas. Estava dentro da
/// `WeekScreen` enquanto só existia uma visão; agora que existem três, mora
/// aqui — senão as outras duas teriam de reimplementá-la, e o cabeçalho é
/// justamente o que não pode mudar ao trocar de aba.
struct CalendarHeader: View {

    /// Protótipo: `height: 46px; gap: 14px; padding: 0 22px`.
    static let height: CGFloat = 46

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
    var onCreate: () -> Void = {}

    var body: some View {
        HStack(spacing: 14) {
            // Largura reservada, e não largura medida: era daqui que vinha o
            // defeito dos "controles que andam". Ver `ReservedText`.
            ReservedText(
                text: title,
                groups: titleCandidates,
                font: theme.serif.font(size: 19, weight: .semibold),
                color: theme.ink.color
            )

            viewTabs

            // Nas três visões. Antes só a Dia tinha, e semana e mês ficavam
            // presas na semana e no mês da âncora.
            dayNavigator

            Text(meta)
                .font(theme.mono.font(size: 10))
                .foregroundStyle(theme.ink4.color)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 0)

            CalendarButton(
                appearance: .strong,
                horizontalPadding: 11,
                action: onCreate
            ) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(theme.sans.font(size: 11, weight: .semibold))
                    Text("Novo compromisso")
                        .font(theme.sans.font(size: 11.5, weight: .semibold))
                }
            }
            .help("Adicionar um compromisso à agenda")
            .accessibilityLabel("Novo compromisso")

            accountLegend
        }
        .padding(.horizontal, 22)
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
                WeekAgenda.items(on: selectedDayOffset, in: store.visibleAgenda).count
            )
        case .week:
            "semana \(WeekAgenda.weekNumber(for: focusedDate))"
        case .month:
            "\(MonthAgenda.eventCount(from: store.visibleAgenda, anchor: anchor, focusOffset: selectedDayOffset)) compromissos"
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
        .padding(2)
        .background(theme.surface3.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
    }

    /// Protótipo: `tab(on)` — `height: 24px; padding: 0 13px; font-size: 12.5px;
    /// font-weight: 550`, e a ativa com fundo `surface` e sombra leve.
    private func tab(_ candidate: CalendarViewMode) -> some View {
        let isActive = candidate == mode
        return Button { onPick(candidate) } label: {
            Text(candidate.label)
                .font(theme.sans.font(size: 12.5, weight: .medium))
                .foregroundStyle(isActive ? theme.ink.color : theme.ink3.color)
                .padding(.horizontal, 13)
                .frame(height: 24)
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: theme.radiusSmall)
                            .fill(theme.surface.color)
                            // CSS `0 1px 2px rgba(0,0,0,0.08)`: o raio do SwiftUI
                            // é metade do blur do CSS.
                            .shadow(color: .black.opacity(0.08), radius: 1, x: 0, y: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .accessibilityLabel(candidate.label)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: - O navegador de dia

    /// Protótipo: linhas 1403–1408 — `‹`, o botão do seletor, `›` e "Hoje",
    /// com `gap: 6px`.
    private var dayNavigator: some View {
        HStack(spacing: 6) {
            CalendarButton(
                appearance: .quiet, width: 26, horizontalPadding: 0,
                action: { onStepDay(-1) }
            ) {
                Text("‹").font(theme.sans.font(size: 13))
            }
            .help("Dia anterior")
            .accessibilityLabel("Dia anterior")

            CalendarButton(
                appearance: pickerOpen ? .active : .strong, horizontalPadding: 11,
                action: onTogglePicker
            ) {
                HStack(spacing: 5) {
                    ReservedText(
                        text: MonthAgenda.shortDayLabel(
                            dayOffset: selectedDayOffset, anchor: anchor
                        ),
                        groups: dayLabelCandidates,
                        font: theme.sans.font(size: 12, weight: .medium),
                        color: nil
                    )
                    // Protótipo: `font-size: 8px; opacity: 0.6` no mono.
                    Text("▾")
                        .font(theme.mono.font(size: 8))
                        .opacity(0.6)
                }
            }
            .help("Escolher o dia")
            .accessibilityLabel("Escolher o dia")

            CalendarButton(
                appearance: .quiet, width: 26, horizontalPadding: 0,
                action: { onStepDay(1) }
            ) {
                Text("›").font(theme.sans.font(size: 13))
            }
            .help("Próximo dia")
            .accessibilityLabel("Próximo dia")

            CalendarButton(appearance: .quiet, horizontalPadding: 10, action: onGoToday) {
                Text("Hoje").font(theme.sans.font(size: 11.5, weight: .medium))
            }
            .accessibilityLabel("Ir para hoje")
        }
        // O popover pousa **no navegador**, não na faixa: no protótipo o
        // container das setas é o `position: relative` de quem tem
        // `position: absolute` (linha 1403 e 1410). Pendurá-lo na faixa
        // obrigaria a medir onde o navegador começa — e ele começa depois do
        // título, cuja largura muda com o dia, e depois das abas, cuja largura
        // muda com a fonte do tema.
        //
        // `top: 32px; left: 32px`: 32 à esquerda são a seta `‹` (26) mais o
        // intervalo (6), o que alinha o popover ao botão que o abriu; 32 abaixo
        // são os 26 do botão mais 6 de folga.
        .overlay(alignment: .topLeading) {
            if pickerOpen {
                DatePickerPopover(
                    store: store, anchor: anchor,
                    selectedDayOffset: selectedDayOffset,
                    onPickDay: onPickDay
                )
                .offset(x: 32, y: 32)
            }
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

/// A cor da caixa a que um compromisso pertence, nas quatro visões.
///
/// Conta desconhecida cai no acento do tema: nada aqui presume quais contas
/// existem, nem quantas.
enum CalendarTint {
    @MainActor
    static func color(of accountID: String, in store: MailStore, theme: Theme) -> Color {
        store.account(accountID)
            .flatMap { TokenColor(css: $0.tint(isDark: theme.isDark))?.color }
            ?? theme.accent.color
    }
}

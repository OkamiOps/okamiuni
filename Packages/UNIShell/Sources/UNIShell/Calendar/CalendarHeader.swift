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

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(theme.serif.font(size: 19, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
                .fixedSize()

            viewTabs

            if mode == .day {
                dayNavigator
            }

            Text(meta)
                .font(theme.mono.font(size: 10))
                .foregroundStyle(theme.ink4.color)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 0)

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
            : WeekAgenda.monthTitle(for: anchor)
    }

    /// Protótipo: `calMeta` (linha 2360).
    ///
    /// A contagem do mês é derivada, e não a literal `'12 compromissos'` que o
    /// protótipo escreve — ver `MonthAgenda.eventCount`.
    private var meta: String {
        switch mode {
        case .day:
            DayAgenda.blockCountLabel(
                WeekAgenda.items(on: selectedDayOffset, in: store.agenda).count
            )
        case .week:
            "semana \(WeekAgenda.weekNumber(for: anchor))"
        case .month:
            "\(MonthAgenda.eventCount(from: store.agenda, anchor: anchor)) compromissos"
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
                    Text(MonthAgenda.shortDayLabel(dayOffset: selectedDayOffset, anchor: anchor))
                        .font(theme.sans.font(size: 12, weight: .medium))
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

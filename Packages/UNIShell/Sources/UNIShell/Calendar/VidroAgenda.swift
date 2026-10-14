import SwiftUI
import UNICore
import UNIDesign

/// A Agenda no shell Vidro — `design/Agenda-Vidro.dc.html`.
///
/// Duas coisas moram aqui: a faixa do topo, que troca a cápsula antiga pelo
/// segmentado de 200 pt do protótipo, e as cores dos compromissos, que deixam
/// de ser um cartão opaco com barra à esquerda e passam a ser um retângulo
/// translúcido pintado pela cor do calendário.
///
/// Fora do Vidro nada disto é chamado: `CalendarHeader`, `WeekScreen`,
/// `DayScreen` e `MonthScreen` continuam com o desenho que sempre tiveram.

// MARK: - A faixa do topo

struct VidroAgendaCabecalho: View {

    @Environment(\.theme) private var theme

    let store: MailStore
    let anchor: Date
    let mode: CalendarViewMode
    let selectedDayOffset: Int
    let pickerOpen: Bool
    /// Quantos blocos a IA propôs para hoje. `0` esconde a frase.
    let blocosPropostos: Int
    let onPick: (CalendarViewMode) -> Void
    let onStepDay: (Int) -> Void
    let onGoToday: () -> Void
    let onTogglePicker: () -> Void
    let onPickDay: (Int) -> Void
    /// Presente só com a coluna de contexto recolhida: o `sidebar.left` que a
    /// traz de volta, antes do título do mês.
    var onExpandSidebar: (() -> Void)?

    /// Protótipo: `padding: 16px 22px` e uma hairline embaixo.
    static let height: CGFloat = 60

    var body: some View {
        HStack(spacing: 12) {
            if let onExpandSidebar {
                SidebarToggleButton(collapse: false, action: onExpandSidebar)
            }
            Text(titulo)
                .font(theme.sans.font(size: 22, weight: .bold))
                .tracking(-0.44)
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
                .fixedSize()
            Text(meta)
                .font(theme.sans.font(size: 14))
                .foregroundStyle(theme.ink3.color)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 8)

            if blocosPropostos > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accentInk.color)
                    Text(
                        blocosPropostos == 1
                            ? L10n.tr("1 bloco proposto")
                            : L10n.tr("\(blocosPropostos) blocos propostos")
                    )
                    .font(theme.sans.font(size: 13))
                    .foregroundStyle(theme.ink2.color)
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
            }

            segmentado
            hoje
            navegador
        }
        .padding(.horizontal, 22)
        .frame(height: Self.height)
        .hairline(theme.line, edges: .bottom)
    }

    /// No Vidro o título é só o mês: o ano cabe no mês miúdo da coluna de
    /// contexto, e "Setembro 2026" em 22pt empurrava o segmentado.
    private var titulo: String {
        mode == .day
            ? MonthAgenda.longDayTitle(dayOffset: selectedDayOffset, anchor: anchor)
            : WeekAgenda.monthTitle(for: focusedDate)
                .split(separator: " ").first.map(String.init)
                ?? WeekAgenda.monthTitle(for: focusedDate)
    }

    private var focusedDate: Date {
        Calendar.current.date(byAdding: .day, value: selectedDayOffset, to: anchor) ?? anchor
    }

    private var meta: String {
        switch mode {
        case .day:
            DayAgenda.blockCountLabel(
                WeekAgenda.items(on: selectedDayOffset, in: store.calendarAgenda).count
            )
        case .week:
            L10n.tr("semana \(WeekAgenda.weekNumber(for: focusedDate))")
        case .month:
            L10n.tr("\(MonthAgenda.eventCount(from: store.calendarAgenda, anchor: anchor, focusOffset: selectedDayOffset)) compromissos")
        }
    }

    /// Protótipo: três colunas iguais em 200 pt, com o escolhido num cartão.
    private var segmentado: some View {
        HStack(spacing: 0) {
            ForEach(CalendarViewMode.allCases) { candidato in
                let ativo = candidato == mode
                Button { onPick(candidato) } label: {
                    Text(candidato.label)
                        .font(theme.sans.font(size: 13, weight: ativo ? .semibold : .regular))
                        .foregroundStyle(ativo ? theme.ink.color : theme.ink2.color)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background {
                            if ativo {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(theme.glassActive.color)
                                    .shadow(
                                        color: theme.isDark ? .clear : .black.opacity(0.12),
                                        radius: 1, x: 0, y: 1
                                    )
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: 7)
                .accessibilityLabel(candidato.label)
                .accessibilityAddTraits(ativo ? [.isSelected] : [])
            }
        }
        .padding(3)
        .frame(width: 200)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.glassSoft.color)
        )
    }

    private var hoje: some View {
        Button(action: onGoToday) {
            Text(L10n.tr("Hoje"))
                .font(theme.sans.font(size: 13, weight: .medium))
                .foregroundStyle(theme.ink.color)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(theme.glassSoft.color)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 9)
        .disabled(selectedDayOffset == 0)
        .help(L10n.tr("Ir para hoje"))
        .accessibilityLabel(L10n.tr("Ir para hoje"))
    }

    /// `‹ dia ›`: o seletor de data continua aqui, com o popover de sempre.
    private var navegador: some View {
        HStack(spacing: 4) {
            passo(-1, "chevron.left", previousLabel)
            Button(action: onTogglePicker) {
                HStack(spacing: 5) {
                    Text(MonthAgenda.shortDayLabel(
                        dayOffset: selectedDayOffset, anchor: anchor
                    ))
                    .font(theme.sans.font(size: 12.5, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.7)
                }
                .foregroundStyle(theme.ink2.color)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(pickerOpen ? theme.glassActive.color : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: 9)
            .help(L10n.tr("Escolher o dia"))
            .accessibilityLabel(L10n.tr("Escolher o dia"))
            passo(1, "chevron.right", nextLabel)
        }
        .overlay(alignment: .topLeading) {
            if pickerOpen {
                DatePickerPopover(
                    store: store, anchor: anchor,
                    selectedDayOffset: selectedDayOffset,
                    onPickDay: onPickDay
                )
                .offset(x: -60, y: 36)
            }
        }
    }

    private func passo(_ direcao: Int, _ simbolo: String, _ rotulo: String) -> some View {
        Button { onStepDay(direcao) } label: {
            Image(systemName: simbolo)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.ink2.color)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 9)
        .help(rotulo)
        .accessibilityLabel(rotulo)
    }

    private var previousLabel: String {
        switch mode {
        case .day: L10n.tr("Dia anterior")
        case .week: L10n.tr("Semana anterior")
        case .month: L10n.tr("Mês anterior")
        }
    }

    private var nextLabel: String {
        switch mode {
        case .day: L10n.tr("Próximo dia")
        case .week: L10n.tr("Próxima semana")
        case .month: L10n.tr("Próximo mês")
        }
    }
}

// MARK: - O número do dia

/// O número do dia na faixa da semana e do mês: hoje ganha um círculo cheio
/// em accent com o número branco, como no protótipo.
struct VidroNumeroDoDia: View {

    @Environment(\.theme) private var theme

    let weekday: String
    let numero: Int
    let hoje: Bool
    var tamanho: CGFloat = 18
    var diametro: CGFloat = 32

    var body: some View {
        HStack(spacing: 6) {
            Text(weekday)
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink3.color)
            Text("\(numero)")
                .font(theme.sans.font(size: tamanho, weight: .semibold))
                .foregroundStyle(hoje ? theme.onAccent.color : theme.ink.color)
                .frame(width: diametro, height: diametro)
                .background {
                    if hoje { Circle().fill(theme.accent.color) }
                }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - As cores do compromisso

/// O cartão do compromisso no Vidro: fundo translúcido na cor do calendário,
/// texto na mesma cor, sem barra à esquerda.
enum VidroEvento {

    @MainActor
    static func fill(_ item: AgendaItem, in store: MailStore, theme: Theme) -> Color {
        if item.isCancelled {
            return theme.ink4.color.opacity(theme.isDark ? 0.12 : 0.10)
        }
        let tinta = CalendarTint.token(of: item, in: store, theme: theme) ?? theme.accent
        return theme.glassEventFill(tinta).color
    }

    @MainActor
    static func ink(_ item: AgendaItem, in store: MailStore, theme: Theme) -> Color {
        if item.isCancelled { return theme.ink4.color }
        let tinta = CalendarTint.token(of: item, in: store, theme: theme) ?? theme.accent
        return theme.glassEventInk(tinta).color
    }

    /// O canto do protótipo: 8 pt em todos os quatro lados.
    static let radius: CGFloat = 8
}

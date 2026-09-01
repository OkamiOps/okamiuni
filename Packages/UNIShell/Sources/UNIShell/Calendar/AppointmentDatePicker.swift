import SwiftUI
import UNIDesign
import UNICore

/// Grade de mês no tema do OkamiUNI — a mesma linguagem do seletor da Agenda.
/// O `DatePicker` compacto do sistema sai preto, com data no formato errado;
/// este desenha os dias no papel do app.
struct AppointmentDatePicker: View {
    static let cellHeight: CGFloat = 28
    static let cellGap: CGFloat = 2

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let store: MailStore
    let anchor: Date
    @Binding var day: Date

    @State private var focusedMonth: Date

    init(store: MailStore, anchor: Date, day: Binding<Date>) {
        self.store = store
        self.anchor = anchor
        _day = day
        _focusedMonth = State(initialValue: Calendar.current.startOfDay(for: day.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            grid
        }
        .onChange(of: day) { _, newDay in
            let calendar = Calendar.current
            if calendar.component(.month, from: newDay) != calendar.component(.month, from: focusedMonth)
                || calendar.component(.year, from: newDay) != calendar.component(.year, from: focusedMonth)
            {
                focusedMonth = calendar.startOfDay(for: newDay)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(WeekAgenda.monthTitle(for: focusedMonth))
                .font(theme.serif.font(size: 14, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Spacer(minLength: 0)
            CalendarButton(
                appearance: .quiet, width: 28, height: 28, horizontalPadding: 0,
                action: { stepMonth(-1) }
            ) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .accessibilityLabel("Mês anterior")
            CalendarButton(
                appearance: .quiet, width: 28, height: 28, horizontalPadding: 0,
                action: { stepMonth(1) }
            ) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .accessibilityLabel("Próximo mês")
        }
    }

    private var grid: some View {
        let weeks = MonthAgenda.weeks(
            from: store.calendarAgenda, anchor: anchor, focusOffset: focusOffset
        )
        return VStack(spacing: Self.cellGap) {
            HStack(spacing: Self.cellGap) {
                ForEach(Array(MonthAgenda.columnLabels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(theme.mono.font(size: 8.5))
                        .tracking(0.51)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.ink4.color)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 2)
                }
            }
            ForEach(weeks) { week in
                HStack(spacing: Self.cellGap) {
                    ForEach(week.days) { cell in
                        dayCell(cell)
                    }
                }
            }
        }
    }

    private func dayCell(_ cell: MonthAgenda.Day) -> some View {
        let selected = cell.dayOffset == selectedOffset
        return Button {
            pick(cell.dayOffset)
        } label: {
            ZStack {
                Text("\(cell.dayNumber)")
                    .font(theme.sans.font(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(numberColor(cell, selected: selected))
                VStack {
                    Spacer(minLength: 0)
                    Circle()
                        .fill(dotColor(cell, selected: selected))
                        .frame(width: 3, height: 3)
                        .padding(.bottom, 3)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.cellHeight)
            .background(cellBackground(cell, selected: selected))
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(MonthAgenda.longDayTitle(dayOffset: cell.dayOffset, anchor: anchor))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var selectedOffset: Int {
        Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: anchor),
            to: Calendar.current.startOfDay(for: day)
        ).day ?? 0
    }

    private var focusOffset: Int {
        Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: anchor),
            to: Calendar.current.startOfDay(for: focusedMonth)
        ).day ?? 0
    }

    private func pick(_ offset: Int) {
        let calendar = Calendar.current
        let newDay = calendar.date(
            byAdding: .day, value: offset, to: calendar.startOfDay(for: anchor)
        ) ?? day
        day = calendar.startOfDay(for: newDay)
    }

    private func stepMonth(_ delta: Int) {
        focusedMonth = Calendar.current.date(byAdding: .month, value: delta, to: focusedMonth)
            ?? focusedMonth
    }

    private func numberColor(_ cell: MonthAgenda.Day, selected: Bool) -> Color {
        if selected { return theme.onAccent.color }
        if cell.isOutsideMonth { return theme.ink4.color }
        if cell.isToday { return theme.accent.color }
        return theme.ink2.color
    }

    private func cellBackground(_ cell: MonthAgenda.Day, selected: Bool) -> Color {
        if selected { return theme.accent.color }
        if cell.isToday { return theme.accentSoft.color }
        return .clear
    }

    private func dotColor(_ cell: MonthAgenda.Day, selected: Bool) -> Color {
        guard cell.hasEvents else { return .clear }
        return selected ? theme.onAccent.color.opacity(0.8) : theme.accent.color
    }
}

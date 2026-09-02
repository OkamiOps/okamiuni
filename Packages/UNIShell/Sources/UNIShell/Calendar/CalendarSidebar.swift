import SwiftUI
import UNICore
import UNIDesign

/// A lateral da aba Agenda: calendários do macOS, agrupados pela origem
/// (Todoist, iCloud, Gmail…), com um interruptor por calendário.
///
/// Substitui a `FolderSidebar` do email nesta aba. Filtrar a grade pela
/// caixa de correio escondia Todoist e o resto do EventKit.
struct CalendarSidebar: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let store: MailStore
    let width: CGFloat
    let intelligencePresentation: IntelligencePresentation
    let onOpenAssistant: () -> Void
    let onCreate: () -> Void
    var onOpenAccounts: (() -> Void)? = nil
    var anchor: Date = Fixtures.today
    var selectedDayOffset: Int = 0
    var onPickDay: (Int) -> Void = { _ in }

    @State private var chevronHovering: String?

    nonisolated static let chevronSize: CGFloat = 11
    nonisolated static let chevronTargetWidth: CGFloat = 18
    nonisolated static let chevronTargetHeight: CGFloat = 24

    private var compact: Bool { width <= PaneLayout.railWidth + 8 }

    var body: some View {
        Group {
            if compact { rail } else { expanded }
        }
        .frame(width: width, alignment: compact ? .center : .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .trailing)
        // Sem isto o cartão da IA, na trilha de 72pt, vazava para a grade.
        .clipped()
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            createButton
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 10)

            CalendarMiniMonth(
                store: store,
                anchor: anchor,
                selectedDayOffset: selectedDayOffset,
                onPickDay: onPickDay
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            ScrollView {
                groupedList
            }

            Rectangle()
                .fill(theme.line.color)
                .frame(height: Hairline.thickness(displayScale))
            VStack(spacing: 8) {
                IntelligenceFooter(
                    presentation: intelligencePresentation,
                    onOpenAssistant: onOpenAssistant,
                    onOpenSettings: { onOpenAccounts?() }
                )
                refreshButton
            }
            .padding(10)
        }
    }

    /// A mesma trilha de 72pt do email: botão 46pt, marcas, IA, atualizar.
    /// Empilhar o cartão expandido aqui era o que quebrava o recuo.
    private var rail: some View {
        VStack(alignment: .center, spacing: 4) {
            compactCreate

            ScrollView {
                VStack(alignment: .center, spacing: 6) {
                    Rectangle()
                        .fill(theme.line.color)
                        .frame(width: 26, height: Hairline.thickness(displayScale))
                        .padding(.vertical, 8)
                    ForEach(groups, id: \.source) { group in
                        Text(group.source)
                            .font(theme.mono.font(size: 7.5))
                            .tracking(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(theme.ink4.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.top, 4)
                            .padding(.bottom, 2)
                        ForEach(group.calendars) { calendar in
                            railMark(calendar, among: group.calendars)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Spacer(minLength: 8)
            IntelligenceFooter(
                presentation: intelligencePresentation,
                onOpenAssistant: onOpenAssistant,
                onOpenSettings: { onOpenAccounts?() },
                compact: true
            )
            compactRefresh
        }
        .padding(.vertical, 14)
    }

    private var groups: [(source: String, calendars: [ConnectedCalendar])] {
        let list = store.visibleCalendarsForSidebar
        let grouped = Dictionary(grouping: list, by: \.source)
        let order = grouped.keys.sorted { a, b in
            if a == ConnectedCalendar.email.source { return false }
            if b == ConnectedCalendar.email.source { return true }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return order.map { source in
            let calendars = (grouped[source] ?? []).sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return (source, calendars)
        }
    }

    private var groupedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Calendários")
                .capsLabel(size: 9.5)
                .padding(EdgeInsets(top: 4, leading: 16, bottom: 7, trailing: 16))

            if groups.isEmpty {
                Text(emptyCopy)
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(theme.ink3.color)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            ForEach(groups, id: \.source) { group in
                sourceHeader(group.source)
                if store.calendarSourceExpanded(group.source) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(group.calendars) { calendar in
                            calendarRow(calendar, concealed: false)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            if !store.concealedCalendarsForSidebar.isEmpty {
                sourceHeader(MailStore.concealedCalendarsSection)
                if store.calendarSourceExpanded(MailStore.concealedCalendarsSection) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(store.concealedCalendarsForSidebar) { calendar in
                            calendarRow(calendar, concealed: true)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func railMark(_ calendar: ConnectedCalendar, among siblings: [ConnectedCalendar]) -> some View {
        let on = store.isCalendarEnabled(calendar.id)
        let color = Self.tint(calendar.colorHex)
        let mark = CalendarMark.rail(calendar, among: siblings)
        let label = calendar.source == calendar.title
            ? calendar.title
            : "\(calendar.source) · \(calendar.title)"
        return Button {
            store.toggleCalendar(calendar.id)
        } label: {
            Text(mark)
                .font(theme.mono.font(size: 10, weight: .medium))
                .foregroundStyle(color.opacity(on ? 1 : 0.38))
                .frame(width: 40, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .fill(color.opacity(on ? 0.22 : 0.08))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(
                            color.opacity(on ? 0.55 : 0.18),
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
        }
        .buttonStyle(.plain)
        .uniContextMenu(
            ContextMenus.calendarRow(calendar, isConcealed: false),
            store: store
        )
        .help(on ? "Esconder \(label)" : "Mostrar \(label)")
        .accessibilityLabel(calendar.title)
        .accessibilityValue(on ? "visível" : "escondido")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func sourceHeader(_ source: String) -> some View {
        let expanded = store.calendarSourceExpanded(source)
        return Button {
            store.toggleCalendarSource(source)
        } label: {
            HStack(spacing: 6) {
                Text(expanded ? "▾" : "▸")
                    .font(theme.mono.font(size: Self.chevronSize))
                    .foregroundStyle(
                        (chevronHovering == source ? theme.ink2 : theme.ink3).color
                    )
                    .frame(width: Self.chevronTargetWidth, height: Self.chevronTargetHeight)
                    .background(
                        chevronHovering == source ? theme.surface3.color : .clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                Text(source)
                    .font(theme.sans.font(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink3.color)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { chevronHovering = $0 ? source : nil }
        .help(expanded ? "Recolher \(source)" : "Mostrar os calendários de \(source)")
        .accessibilityLabel(source)
        .accessibilityValue(expanded ? "aberto" : "recolhido")
        .accessibilityAddTraits(expanded ? [.isSelected] : [])
    }

    private func calendarRow(_ calendar: ConnectedCalendar, concealed: Bool) -> some View {
        let on = !concealed && store.isCalendarEnabled(calendar.id)
        return Button {
            if concealed {
                store.revealCalendar(calendar.id)
            } else {
                store.toggleCalendar(calendar.id)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: concealed ? "eye.slash" : (on ? "checkmark.square.fill" : "square"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle((on ? Self.tint(calendar.colorHex) : theme.ink4.color))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Circle()
                    .fill(Self.tint(calendar.colorHex).opacity(concealed ? 0.4 : 1))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(calendar.title)
                    .font(theme.sans.font(size: 13, weight: .medium))
                    .foregroundStyle((on ? theme.ink2 : theme.ink3).color)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 32)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background {
                if on {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .fill(theme.surface.color.opacity(0.55))
                }
            }
        }
        .buttonStyle(.plain)
        .uniContextMenu(
            ContextMenus.calendarRow(calendar, isConcealed: concealed),
            store: store
        )
        .help(
            concealed
                ? "Mostrar \(calendar.title) na lista"
                : (on ? "Esconder \(calendar.title) na grade" : "Mostrar \(calendar.title) na grade")
        )
        .accessibilityLabel(calendar.title)
        .accessibilityValue(concealed ? "oculto" : (on ? "visível" : "desligado"))
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private var createButton: some View {
        Button(action: onCreate) {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                Text("Novo compromisso")
                    .font(theme.sans.font(size: 13, weight: .semibold))
            }
            .foregroundStyle(theme.onAccent.color)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(theme.accent.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall, tint: \.onAccent)
        .help("Novo compromisso")
        .accessibilityLabel("Novo compromisso")
    }

    private var compactCreate: some View {
        Button(action: onCreate) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.onAccent.color)
                .frame(width: 46, height: 42)
                .background(theme.accent.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall, tint: \.onAccent)
        .help("Novo compromisso")
        .accessibilityLabel("Novo compromisso")
    }

    private var compactRefresh: some View {
        Button {
            Task { await store.refreshCalendar(requestAuthorization: true) }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.ink2.color)
                .frame(width: 46, height: 40)
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .help("Sincronizar os calendários do macOS e das caixas conectadas agora")
        .accessibilityLabel("Atualizar agendas")
    }

    private var refreshButton: some View {
        Button {
            Task { await store.refreshCalendar(requestAuthorization: true) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                Text("Atualizar agendas")
                    .font(theme.sans.font(size: 12.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.ink2.color)
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .help("Sincronizar os calendários do macOS e das caixas conectadas agora")
        .accessibilityLabel("Atualizar agendas")
    }

    private var emptyCopy: String {
        switch store.calendarAvailability {
        case .authorizationRequired:
            "Permita o acesso aos Calendários para listar iCloud, Todoist e os outros."
        case .unavailable(let reason):
            reason
        case .loading:
            "Lendo os calendários deste Mac…"
        default:
            "Nenhum calendário encontrado neste Mac."
        }
    }

    static func tint(_ hex: String) -> Color {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else {
            return Color(red: 0.24, green: 0.44, blue: 0.66)
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Mini calendário da lateral: o mês em 6×7, com ponto nos dias que têm
/// compromisso. Clicar num dia leva a grade principal até ele.
struct CalendarMiniMonth: View {
    static let cellGap: CGFloat = 1
    static let cellHeight: CGFloat = 22

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let store: MailStore
    let anchor: Date
    let selectedDayOffset: Int
    let onPickDay: (Int) -> Void

    @State private var monthFocusOffset = 0

    var weeks: [MonthAgenda.Week] {
        MonthAgenda.weeks(
            from: store.calendarAgenda, anchor: anchor, focusOffset: monthFocusOffset
        )
    }

    var focusedDate: Date {
        MonthAgenda.focusedDate(anchor: anchor, focusOffset: monthFocusOffset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            grid
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusSmall)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .onAppear { monthFocusOffset = selectedDayOffset }
        .onChange(of: selectedDayOffset) { _, new in
            let inMonth = weeks.flatMap(\.days).contains {
                !$0.isOutsideMonth && $0.dayOffset == new
            }
            if !inMonth { monthFocusOffset = new }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mini calendário")
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                monthFocusOffset = MonthAgenda.navigationStep(
                    days: .month, from: monthFocusOffset, anchor: anchor, direction: -1
                )
            } label: {
                Text("‹")
                    .font(theme.sans.font(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink2.color)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Mês anterior")
            .accessibilityLabel("Mês anterior")

            Text(WeekAgenda.monthTitle(for: focusedDate))
                .font(theme.serif.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            Button {
                monthFocusOffset = MonthAgenda.navigationStep(
                    days: .month, from: monthFocusOffset, anchor: anchor, direction: 1
                )
            } label: {
                Text("›")
                    .font(theme.sans.font(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink2.color)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Próximo mês")
            .accessibilityLabel("Próximo mês")
        }
    }

    private var grid: some View {
        VStack(spacing: Self.cellGap) {
            HStack(spacing: Self.cellGap) {
                ForEach(Array(MonthAgenda.columnLabels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(theme.mono.font(size: 8))
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.ink4.color)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(weeks) { week in
                HStack(spacing: Self.cellGap) {
                    ForEach(week.days) { day in
                        cell(day)
                    }
                }
            }
        }
    }

    private func cell(_ day: MonthAgenda.Day) -> some View {
        let isSelected = day.dayOffset == selectedDayOffset
        return Button { onPickDay(day.dayOffset) } label: {
            ZStack {
                Text("\(day.dayNumber)")
                    .font(theme.sans.font(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(numberColor(day, isSelected: isSelected))
                VStack {
                    Spacer(minLength: 0)
                    Circle()
                        .fill(dotColor(day, isSelected: isSelected))
                        .frame(width: 3, height: 3)
                        .padding(.bottom, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.cellHeight)
            .background(cellBackground(day, isSelected: isSelected))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(MonthAgenda.longDayTitle(dayOffset: day.dayOffset, anchor: anchor))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func numberColor(_ day: MonthAgenda.Day, isSelected: Bool) -> Color {
        if isSelected { return theme.onAccent.color }
        if day.isOutsideMonth { return theme.ink4.color }
        if day.isToday { return theme.accent.color }
        return theme.ink2.color
    }

    private func cellBackground(_ day: MonthAgenda.Day, isSelected: Bool) -> Color {
        if isSelected { return theme.accent.color }
        if day.isToday { return theme.accentSoft.color }
        return .clear
    }

    private func dotColor(_ day: MonthAgenda.Day, isSelected: Bool) -> Color {
        guard day.hasEvents else { return .clear }
        return isSelected ? theme.onAccent.color.opacity(0.8) : theme.accent.color
    }
}

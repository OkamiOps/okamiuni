import SwiftUI
import UNIDesign
import UNICore

/// O seletor de data de 244pt da visão Dia (protótipo, linhas 1409–1428).
///
/// Desenha a **mesma** grade da visão Mês — no protótipo `pickerDays` e
/// `monthWeeks` saem os dois da constante `MONTH`. Continuar assim é o que
/// impede o ponto embaixo do número aqui e o cartão do mês lá discordarem sobre
/// que dia tem compromisso.
struct DatePickerPopover: View {

    /// Protótipo: `width: 244px; padding: 12px`.
    static let width: CGFloat = 244
    static let padding: CGFloat = 12

    /// Protótipo: `height: 26px` nas células e `gap: 2px` na grade.
    static let cellHeight: CGFloat = 26
    static let cellGap: CGFloat = 2

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let store: MailStore
    let anchor: Date
    let selectedDayOffset: Int
    let onPickDay: (Int) -> Void

    /// O mês/semana **focado**, não o da âncora: navegar com `‹ ›` antes de
    /// abrir o seletor não pode fazer a grade voltar para trás. A âncora nunca
    /// se move — só o `focusOffset` que o navegador acumulou anda.
    ///
    /// `internal`, não `private`: `DatePickerPopoverTests` precisa ler isto
    /// para provar a navegação sem depender de renderizar pixel.
    var weeks: [MonthAgenda.Week] {
        MonthAgenda.weeks(from: store.visibleAgenda, anchor: anchor, focusOffset: selectedDayOffset)
    }

    /// A data que o cabeçalho e a grade devem usar para achar o mês em foco.
    /// `Day.dayOffset` que a grade produz continua relativo a `anchor` — é o
    /// que faz `onPickDay` devolver o mesmo tipo de deslocamento que
    /// `selectedDayOffset` já é, sem teleportar a navegação de volta para a
    /// âncora ao escolher um dia.
    var focusedDate: Date {
        MonthAgenda.focusedDate(anchor: anchor, focusOffset: selectedDayOffset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            grid
        }
        // Os 244 do protótipo são a largura do **conteúdo**: aquele elemento
        // não declara `box-sizing: border-box` (o autor o declara onde quer,
        // e ali não quis), então os 12pt de recuo somam por fora. Medido no
        // navegador: `width` computado 244px, caixa de 270px com a borda.
        // Cravar 244 no quadro externo encolheria a grade em 24pt e as células
        // de 33,1 para 30,3.
        .frame(width: Self.width)
        .padding(Self.padding)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                // Um pixel do dispositivo — ver `Hairline.thickness(_:)`.
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        // Protótipo: `box-shadow: 0 18px 40px rgba(0,0,0,0.28)`. O raio do
        // SwiftUI é metade do blur do CSS.
        .shadow(color: .black.opacity(0.28), radius: 20, x: 0, y: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Escolher o dia")
    }

    /// Protótipo: `margin-bottom: 9px`, o mês em serif 14 e o rótulo em mono 9.
    private var header: some View {
        HStack(spacing: 8) {
            Text(WeekAgenda.monthTitle(for: focusedDate))
                .font(theme.serif.font(size: 14, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Spacer(minLength: 0)
            Text("escolher dia")
                .capsLabel(size: 9)
        }
        .padding(.bottom, 9)
    }

    private var grid: some View {
        VStack(spacing: Self.cellGap) {
            HStack(spacing: Self.cellGap) {
                ForEach(Array(MonthAgenda.columnLabels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(theme.mono.font(size: 8.5))
                        // CSS `letter-spacing: 0.06em` a 8.5pt = 0.51pt. Aqui é
                        // literal do protótipo, e não `theme.capsTracking`: o
                        // `--caps` do tema vale para os cabeçalhos de seção, e
                        // este rótulo tem espaçamento próprio.
                        .tracking(0.51)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.ink4.color)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 3)
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

    /// Protótipo: `p.style` e `p.dotStyle` (linhas 2379–2386).
    private func cell(_ day: MonthAgenda.Day) -> some View {
        let isSelected = day.dayOffset == selectedDayOffset
        return Button { onPickDay(day.dayOffset) } label: {
            ZStack {
                Text("\(day.dayNumber)")
                    .font(theme.sans.font(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(numberColor(day, isSelected: isSelected))

                // Protótipo: `bottom: 3px`, 3×3, centrado. Um ponto transparente
                // ocupa o mesmo espaço de um pintado, então a célula com e sem
                // compromisso mede igual — o número não pula de linha.
                VStack {
                    Spacer(minLength: 0)
                    Circle()
                        .fill(dotColor(day, isSelected: isSelected))
                        .frame(width: 3, height: 3)
                        .padding(.bottom, 3)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.cellHeight)
            .background(cellBackground(day, isSelected: isSelected))
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .accessibilityLabel(accessibilityLabel(day))
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

    /// Protótipo: `rgba(255,255,255,0.8)` sobre o acento cheio, senão o acento.
    /// Sobre o acento a tinta é a do próprio tema (`on-accent`), e não branco
    /// cravado: em tema claro de acento claro o branco sumiria.
    private func dotColor(_ day: MonthAgenda.Day, isSelected: Bool) -> Color {
        guard day.hasEvents else { return .clear }
        return isSelected ? theme.onAccent.color.opacity(0.8) : theme.accent.color
    }

    private func accessibilityLabel(_ day: MonthAgenda.Day) -> String {
        let date = MonthAgenda.longDayTitle(dayOffset: day.dayOffset, anchor: anchor)
        guard day.hasEvents else { return date }
        return "\(date), \(DayAgenda.blockCountLabel(day.events.count))"
    }
}

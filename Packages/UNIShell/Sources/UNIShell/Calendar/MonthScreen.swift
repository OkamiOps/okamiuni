import SwiftUI
import UNIDesign
import UNICore

/// A visão **Mês** da tela 02 (protótipo, linhas 1439–1462): seis linhas de
/// sete células, cada uma com o número do dia e os compromissos empilhados.
///
/// Não rola: as seis linhas dividem a altura disponível (`flex: 1` no
/// protótipo, medido em 130,3pt cada numa janela de 1440×916). Uma célula que
/// não caiba corta os compromissos que sobram, como o protótipo faz — a visão
/// Mês é panorama, e quem quer a lista de um dia troca para a visão Dia.
public struct MonthScreen: View {

    @Environment(\.theme) private var theme
    /// O recibo com "Desfazer" de "Tirar da agenda". Opcional no ambiente,
    /// como em toda superfície: harness e preview não precisam prover nada.
    @Environment(ActionReceipts.self) private var receipts: ActionReceipts?

    let store: MailStore
    let anchor: Date
    /// Qual semana/mês mostrar, em dias a partir de `anchor`. Ver
    /// `CalendarViewMode.navigationScope`.
    var focusOffset: Int = 0
    let onOpenEvent: (AgendaItem) -> Void
    /// Clicar no número do dia leva para a visão Dia naquele dia. É o que a
    /// visão Mês precisa para não ser um beco: o protótipo só dá clique no
    /// cartão do compromisso, e um mês inteiro sem caminho para o dia obriga a
    /// voltar pelo seletor de data.
    let onOpenDay: (Int) -> Void
    /// "Ir para o email de origem", do menu de contexto do cartão. Recebe o id
    /// da mensagem; quem sabe levar o leitor até ela é o `InboxScreen`.
    let onRevealMessage: (String) -> Void

    public init(
        store: MailStore,
        anchor: Date,
        focusOffset: Int = 0,
        onOpenEvent: @escaping (AgendaItem) -> Void = { _ in },
        onOpenDay: @escaping (Int) -> Void = { _ in },
        onRevealMessage: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.anchor = anchor
        self.focusOffset = focusOffset
        self.onOpenEvent = onOpenEvent
        self.onOpenDay = onOpenDay
        self.onRevealMessage = onRevealMessage
    }

    private var weeks: [MonthAgenda.Week] {
        MonthAgenda.weeks(from: store.calendarAgenda, anchor: anchor, focusOffset: focusOffset)
    }

    public var body: some View {
        VStack(spacing: 0) {
            columnHeader
            ForEach(weeks) { week in
                weekRow(week)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surface.color)
    }

    /// Protótipo: `padding: 7px 10px` por célula, mono 9,5 em versalete.
    private var columnHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(MonthAgenda.columnLabels.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .capsLabel(size: 9.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .hairline(theme.line2, edges: .leading)
            }
        }
        .hairline(theme.line2, edges: .bottom)
    }

    private func weekRow(_ week: MonthAgenda.Week) -> some View {
        HStack(spacing: 0) {
            ForEach(week.days) { day in
                cell(day)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hairline(theme.line2, edges: .bottom)
    }

    /// Protótipo: `d.cellStyle` e `d.numStyle` (linhas 2406–2410).
    ///
    /// O conteúdo entra por **sobreposição a um `Color.clear`**, e não direto
    /// na célula. `Color.clear` não tem altura própria, então a linha da semana
    /// fica com a fatia que o `VStack` distribuiu e nada mais; a sobreposição é
    /// recortada no que couber. Sem isso, a linha de 24 a 30 — em que a terça
    /// tem cinco compromissos — pedia 134pt enquanto as outras cinco linhas
    /// mediam 108, e a grade deixava de ser grade. Protótipo: `flex: 1` com
    /// `min-height: 0` e `overflow: hidden`, que é a mesma coisa dita em CSS.
    private func cell(_ day: MonthAgenda.Day) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) { cellContent(day) }
            .clipped()
            .background(cellBackground(day))
            .hairline(theme.line2, edges: .leading)
    }

    private func cellContent(_ day: MonthAgenda.Day) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { onOpenDay(day.dayOffset) } label: {
                Text("\(day.dayNumber)")
                    .font(theme.serif.font(size: 15, weight: .medium))
                    .foregroundStyle(numberColor(day))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall)
            .help("Abre este dia")
            .accessibilityLabel(
                MonthAgenda.longDayTitle(dayOffset: day.dayOffset, anchor: anchor)
            )

            // Protótipo: `gap: 3px; margin-top: 5px`.
            VStack(alignment: .leading, spacing: 3) {
                ForEach(day.events) { event in
                    eventChip(event)
                }
            }
            .padding(.top, 5)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Protótipo: `padding: 6px 8px 8px`.
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    /// Protótipo: `e.style` (linhas 2415–2416).
    private func eventChip(_ event: AgendaItem) -> some View {
        let swatch = CalendarTint.token(of: event, in: store, theme: theme)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: theme.radiusSmall,
            topTrailingRadius: theme.radiusSmall
        )

        let cancelled = event.isCancelled
        return Button { onOpenEvent(event) } label: {
            CalendarEventChrome.title(event.title, cancelled: cancelled)
                .font(theme.sans.font(size: 10.5, weight: .medium))
                .foregroundStyle(CalendarEventChrome.ink(swatch, cancelled: cancelled, theme: theme))
                .lineLimit(1)
                .truncationMode(.tail)
                // Protótipo: `padding: 2px 6px`, e o 6 conta a partir da faixa
                // de cor — `border-left` do CSS fica fora do padding.
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CalendarEventChrome.fill(swatch, cancelled: cancelled, theme: theme))
                // A faixa de 2pt vem por **sobreposição**, não como irmã num
                // `HStack`. Uma `Rectangle` irmã não tem altura própria e pede
                // o máximo disponível: dentro de uma célula do mês, que tem
                // altura de sobra, ela esticava a pastilha de 16pt para mais de
                // 50 e três compromissos estouravam a linha. Nos cartões da
                // semana e do dia o mesmo `HStack` funciona porque lá a altura
                // do cartão é imposta por fora.
                .overlay(alignment: .leading) {
                    Rectangle().fill(CalendarEventChrome.bar(swatch, cancelled: cancelled, theme: theme)).frame(width: 2)
                }
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(CalendarEventChrome.border(cancelled: cancelled, theme: theme), lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(in: shape)
        .help("\(event.title) · \(event.rangeLabel)")
        .accessibilityLabel("\(event.title), \(event.rangeLabel)")
        .uniContextMenu(
            AgendaContextMenu.entries(for: event, store: store, anchor: anchor),
            store: store,
            onReveal: onRevealMessage,
            // "Tirar da agenda" para aqui primeiro, para o recibo com
            // "Desfazer" nascer antes da mudança — ver `ActionReceipts`.
            intercept: { command in
                guard let receipts else { return false }
                return withAnimation(SwipeMotion.transition) {
                    receipts.interceptAgenda(command, on: store, stamp: ActionReceipts.stamp)
                }
            }
        )
    }

    private func numberColor(_ day: MonthAgenda.Day) -> Color {
        if day.isToday { return theme.accent.color }
        if day.isOutsideMonth { return theme.ink4.color }
        return theme.ink2.color
    }

    private func cellBackground(_ day: MonthAgenda.Day) -> Color {
        if day.isToday { return theme.accentSoft.color }
        if day.isOutsideMonth { return theme.surface2.color }
        return .clear
    }
}

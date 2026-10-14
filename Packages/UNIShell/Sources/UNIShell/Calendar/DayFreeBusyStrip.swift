import SwiftUI
import UNICore
import UNIDesign

/// A trilha de 8h às 19h do dia escolhido, dentro da folha de novo
/// compromisso — com o compromisso novo tracejado em cima dela e uma frase que
/// diz se a hora está livre.
///
/// Protótipo (`ModalAgenda.dc.html`, bloco "O dia escolhido"):
/// `height: 30px; border-radius: rSm; background: soft`, faixas em
/// porcentagem, a nova com `border: 1.5px dashed accentInk; background:
/// accentSoft`, e embaixo as doze marcas de hora em mono 10,5 distribuídas de
/// ponta a ponta.
///
/// **Compromisso de verdade, e não exemplo.** As faixas saem de
/// `store.calendarAgenda` filtrado pelo dia da folha; quando o dia está vazio
/// a trilha aparece vazia, que é a informação correta. Nada aqui é fixture.
struct DayFreeBusyStrip: View {
    @Environment(\.theme) private var theme

    let store: MailStore
    /// O dia, contado do mesmo jeito que `AgendaItem.dayOffset`.
    let dayOffset: Int
    let day: Date
    let startMinute: Int
    let endMinute: Int

    /// `height: 30px`.
    static let trackHeight: CGFloat = 30

    private var model: DayFreeBusy {
        DayFreeBusy.build(
            items: store.calendarAgenda,
            dayOffset: dayOffset,
            proposalStart: startMinute,
            proposalEnd: endMinute,
            proposalLabel: L10n.tr("este")
        )
    }

    var body: some View {
        let model = model
        VStack(alignment: .leading, spacing: 8) {
            verdict(model)
            track(model)
            hours
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityPhrase(model))
    }

    // MARK: - A frase

    /// `QUINTA 15` · `● 15h está livre` · `· a Call Marina vem logo depois, às 16h`
    @ViewBuilder
    private func verdict(_ model: DayFreeBusy) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ModalEyebrow(text: DateLabels.shortWeekdayAndDay(day))
            HStack(spacing: 6) {
                Circle()
                    .fill((model.isFree ? theme.modalGreen : theme.warning).color)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(headline(model))
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle((model.isFree ? theme.modalGreen : theme.warning).color)
            }
            if let tail = tail(model) {
                Text(tail)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }

    private func headline(_ model: DayFreeBusy) -> String {
        let hora = DayFreeBusy.clockLabel(startMinute)
        if let clash = model.clash {
            return L10n.tr("\(hora) bate com \(clash.title)")
        }
        return L10n.tr("\(hora) está livre")
    }

    private func tail(_ model: DayFreeBusy) -> String? {
        guard let next = model.next, let minute = model.nextStartMinute else { return nil }
        return L10n.tr("· \(next.title) vem logo depois, às \(DayFreeBusy.clockLabel(minute))")
    }

    private func accessibilityPhrase(_ model: DayFreeBusy) -> String {
        [headline(model), tail(model)].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: - A trilha

    private func track(_ model: DayFreeBusy) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                ForEach(model.bands) { band in
                    bandView(band)
                        .frame(width: max(2, width * band.width), height: Self.trackHeight)
                        .offset(x: width * band.start)
                }
                if let proposal = model.proposal {
                    proposalView(proposal)
                        .frame(width: max(2, width * proposal.width), height: Self.trackHeight)
                        .offset(x: width * proposal.start)
                }
            }
            .frame(width: width, height: Self.trackHeight, alignment: .topLeading)
        }
        .frame(height: Self.trackHeight)
        .background(
            theme.modalSoft.color,
            in: RoundedRectangle(cornerRadius: theme.modalButtonRadius, style: .continuous)
        )
    }

    private func bandView(_ band: DayFreeBusy.Band) -> some View {
        let tint = tint(for: band)
        return Text(band.title)
            .font(theme.sans.font(size: 11.5, weight: .semibold))
            .foregroundStyle(theme.glassEventInk(tint).color)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                theme.glassEventFill(tint).color,
                in: RoundedRectangle(cornerRadius: theme.modalButtonRadius, style: .continuous)
            )
    }

    /// A cor do calendário do compromisso. Uma folga (almoço, café) sai no
    /// verde do protótipo (`rest`), que é o que diz "isto não é reunião".
    private func tint(for band: DayFreeBusy.Band) -> TokenColor {
        if band.isSoft { return theme.modalGreen }
        if let item = store.calendarAgenda.first(where: { $0.id == band.id }),
           let token = CalendarTint.token(of: item, in: store, theme: theme)
        {
            return token
        }
        return theme.liveMeeting
    }

    /// `border: 1.5px dashed accentInk; background: accentSoft`, texto 11,5
    /// bold no acento.
    private func proposalView(_ band: DayFreeBusy.Band) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.modalButtonRadius, style: .continuous)
        return Text(band.title)
            .font(theme.sans.font(size: 11.5, weight: .bold))
            .foregroundStyle(theme.accentInk.color)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(theme.accentSoft.color, in: shape)
            .overlay {
                shape.strokeBorder(
                    theme.accentInk.color,
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5])
                )
            }
    }

    // MARK: - As marcas de hora

    private var hours: some View {
        HStack(spacing: 0) {
            ForEach(Array(DayFreeBusy.hourLabels.enumerated()), id: \.offset) { index, label in
                Text(label)
                    .font(theme.mono.font(size: 10.5))
                    .foregroundStyle(theme.ink3.color)
                if index < DayFreeBusy.hourLabels.count - 1 { Spacer(minLength: 0) }
            }
        }
        .accessibilityHidden(true)
    }
}

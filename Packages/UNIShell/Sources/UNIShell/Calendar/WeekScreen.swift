import SwiftUI
import UNIDesign
import UNICore

/// A visão **Semana** da tela 02 (protótipo, linhas 1499–1530): a faixa dos
/// sete dias e a grade de 00:00 a 24:00.
///
/// **Ela não desenha mais o cabeçalho.** Enquanto era a única visão, a faixa de
/// 46pt morava aqui; agora que Dia e Mês existem, ela mora em `CalendarHeader`,
/// que a `CalendarScreen` põe acima das três. O cabeçalho é justamente o que
/// não pode mudar ao trocar de aba, e três cópias dele mudariam.
public struct WeekScreen: View {

    /// Converte minutos do dia em pontos na grade.
    ///
    /// **Diverge da `AgendaRail.Layout` de propósito, e não por descuido.** A
    /// trilha diária usa 0.78 pt/min na faixa 08:00–19:00; a grade da semana
    /// usa 0.9 pt/min no dia inteiro, 00:00–24:00, porque o protótipo escreve
    /// `top: min * 0.9` e `height: 1300px` (linhas 2422 e 1510). A calha
    /// também é resolvida de outro jeito: 54pt com o rótulo em `left: -50px`,
    /// que deixa 10pt até a linha — folga suficiente para "08:00", então o
    /// ajuste que a trilha precisou fazer na calha não se repete aqui.
    public struct Layout: Sendable {
        /// Protótipo: `min * 0.9`.
        public let pointsPerMinute: CGFloat

        /// Protótipo: `height: 1300px`. São 4pt a mais que 1440 × 0.9 = 1296 —
        /// a folga que impede a última linha de hora de encostar na borda.
        public let totalHeight: CGFloat = 1300

        /// Protótipo: `padding-left: 54px` na faixa de dias e na grade, e
        /// `left: 54px` nas linhas de hora. É a mesma medida nos três, então é
        /// uma constante só: mudar aqui move a grade e os rótulos juntos.
        public let labelGutter: CGFloat = 54

        /// Protótipo: `left: -50px; width: 40px` no rótulo, relativo à linha.
        /// O texto ocupa de x=4 a x=44 e sobram 10pt até a linha em x=54.
        public let labelWidth: CGFloat = 40
        public let labelInset: CGFloat = 50

        /// Protótipo: `left: calc(3px + …)` e `width: calc(… - 5px)`.
        public let eventLeading: CGFloat = 3
        public let eventWidthInset: CGFloat = 5

        /// Protótipo: `height: (e - s) * 0.9 - 3`.
        public let eventHeightInset: CGFloat = 3

        /// Protótipo: `tight = h < 40`. Abaixo disso o cartão perde a linha do
        /// horário e ganha o horário no próprio título.
        public let tightHeight: CGFloat = 40

        public init(pointsPerMinute: CGFloat = 0.9) {
            self.pointsPerMinute = pointsPerMinute
        }

        /// A grade começa em 00:00, então o topo é o minuto vezes a escala —
        /// sem o desconto de 480 que a trilha diária faz.
        public func offset(for item: AgendaItem) -> CGFloat {
            CGFloat(item.startMinute) * pointsPerMinute
        }

        public func offset(minuteOfDay: Int) -> CGFloat {
            CGFloat(minuteOfDay) * pointsPerMinute
        }

        public func height(for item: AgendaItem) -> CGFloat {
            CGFloat(item.durationMinutes) * pointsPerMinute - eventHeightInset
        }

        public func isTight(for item: AgendaItem) -> Bool {
            height(for: item) < tightHeight
        }

        /// Largura de uma coluna de dia, dada a largura da grade.
        public func columnWidth(gridWidth: CGFloat) -> CGFloat {
            max(0, (gridWidth - labelGutter) / 7)
        }

        /// Onde a grade abre a rolagem. Protótipo:
        /// `el.scrollTop = Math.max(0, now * 0.9 - 150)` — o "agora" entra a
        /// 150pt do topo, com o passado ainda visível acima dele.
        public func scrollTarget(now: Int) -> CGFloat {
            max(0, CGFloat(now) * pointsPerMinute - 150)
        }
    }

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let store: MailStore
    let layout: Layout
    /// Minutos desde a meia-noite, injetado para teste.
    let now: Int
    /// O "hoje" do app: de onde saem os números dos dias e o `dayOffset` 0.
    let anchor: Date
    /// Qual semana/mês mostrar, em dias a partir de `anchor`. Ver
    /// `CalendarViewMode.navigationScope`.
    var focusOffset: Int = 0
    /// Clicar num compromisso abre a janela 04.
    let onOpenEvent: (AgendaItem) -> Void
    /// "Ir para o email de origem", do menu de contexto do cartão. Recebe o id
    /// da mensagem; quem sabe levar o leitor até ela é o `InboxScreen`.
    let onRevealMessage: (String) -> Void

    public init(
        store: MailStore,
        layout: Layout = Layout(),
        now: Int? = nil,
        anchor: Date? = nil,
        focusOffset: Int = 0,
        onOpenEvent: @escaping (AgendaItem) -> Void = { _ in },
        onRevealMessage: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.layout = layout
        self.now = now ?? Self.minutesNow()
        self.anchor = anchor ?? Date.now
        self.focusOffset = focusOffset
        self.onOpenEvent = onOpenEvent
        self.onRevealMessage = onRevealMessage
    }

    private static func minutesNow() -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private var days: [WeekAgenda.Day] {
        WeekAgenda.days(from: store.visibleAgenda, anchor: anchor, focusOffset: focusOffset)
    }

    /// Só desenha o traço de "agora" quando hoje está dentro da semana em
    /// exibição — o mesmo padrão de `DayScreen.showsNow`
    /// (`Calendar/DayScreen.swift:126`). Sem esta guarda, `nowMarker` entrava
    /// incondicionalmente na `ZStack` e um `›` continuava mostrando a linha
    /// vermelha e a pastilha "12:00" sobre a semana seguinte, como se o
    /// instante atual estivesse nela. `WeekAgenda.Day.isToday` já é
    /// `offset == 0` relativo à âncora — vale `true` para no máximo um dia da
    /// semana em exibição, e só quando essa semana de fato contém hoje.
    ///
    /// `internal`, não `private`: `WeekScreenTests` precisa ler isto para
    /// provar a guarda sem depender de renderizar pixel.
    var showsNow: Bool { days.contains { $0.isToday } }

    public var body: some View {
        VStack(spacing: 0) {
            dayHeaderStrip
            grid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surface.color)
    }

    // MARK: - Faixa dos dias

    /// Protótipo: `padding-left: 54px`, uma coluna por dia com
    /// `padding: 9px 12px 8px` e divisória à esquerda.
    private var dayHeaderStrip: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: layout.labelGutter, height: 0)
            ForEach(days) { day in
                VStack(alignment: .leading, spacing: 3) {  // protótipo: margin-top: 3px
                    Text(day.weekdayLabel)
                        .font(theme.mono.font(size: 9.5))
                        // CSS `letter-spacing: 0.1em` a 9.5pt = 0.95pt.
                        .tracking(0.95)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.ink4.color)
                    Text("\(day.dayNumber)")
                        .font(theme.serif.font(size: 19, weight: .medium))
                        .foregroundStyle(day.isToday ? theme.accent.color : theme.ink.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 9)
                .padding(.bottom, 8)
                .hairline(theme.line2, edges: .leading)
            }
        }
        .hairline(theme.line2, edges: .bottom)
    }

    // MARK: - A grade

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                GeometryReader { geometry in
                    let columnWidth = layout.columnWidth(gridWidth: geometry.size.width)
                    ZStack(alignment: .topLeading) {
                        // Os fundos das colunas primeiro, as linhas de hora
                        // depois. **Divergência mínima e deliberada:** no
                        // protótipo a coluna de hoje é posicionada e pinta por
                        // cima das linhas, que somem dentro dela. Continuar a
                        // grade por baixo do realce lê como grade; interrompê-la
                        // leria como defeito.
                        columnBackgrounds(columnWidth: columnWidth)
                        hourLines
                        events(columnWidth: columnWidth)
                        if showsNow { nowMarker }
                        scrollAnchor
                    }
                    .frame(width: geometry.size.width, height: layout.totalHeight, alignment: .topLeading)
                }
                .frame(height: layout.totalHeight)
            }
            .onAppear {
                proxy.scrollTo(Self.scrollAnchorID, anchor: .top)
            }
        }
    }

    /// O alvo da rolagem inicial. Ele existe como altura de verdade dentro de
    /// um `VStack` porque `scrollTo` lê o quadro de layout: um `.offset` é
    /// transformação de desenho e não moveria o alvo, e a grade abriria sempre
    /// na meia-noite.
    private static let scrollAnchorID = "week.scroll.now"

    private var scrollAnchor: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: layout.scrollTarget(now: now))
            Color.clear
                .frame(height: 1)
                .id(Self.scrollAnchorID)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }

    /// Protótipo: `flex: 1; border-left: 0.5px solid line2` e
    /// `background: accent-soft` na coluna de hoje.
    private func columnBackgrounds(columnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: layout.labelGutter)
            ForEach(days) { day in
                Rectangle()
                    .fill(day.isToday ? theme.accentSoft.color : Color.clear)
                    .frame(width: columnWidth)
                    .hairline(theme.line2, edges: .leading)
            }
        }
        .frame(height: layout.totalHeight, alignment: .top)
    }

    /// 25 linhas, uma por hora cheia, de 00:00 a 24:00. Protótipo:
    /// `Array.from({ length: 25 })` com `top: min * 0.9`.
    ///
    /// O quadro de altura zero centra o rótulo na linha, como na trilha diária.
    private var hourLines: some View {
        ForEach(0...24, id: \.self) { hour in
            HStack(spacing: 0) {
                Text(Self.hourLabel(minuteOfDay: hour * 60))
                    .font(theme.mono.font(size: 9.5))
                    .foregroundStyle(theme.ink4.color)
                    .frame(width: layout.labelWidth, alignment: .trailing)
                    .padding(.leading, layout.labelGutter - layout.labelInset)
                Spacer(minLength: layout.labelInset - layout.labelWidth)
                Rectangle()
                    .fill(theme.line2.color)
                    .frame(height: Hairline.thickness(displayScale))
            }
            .frame(height: 0, alignment: .center)
            .offset(y: layout.offset(minuteOfDay: hour * 60))
        }
    }

    private func events(columnWidth: CGFloat) -> some View {
        ForEach(days) { day in
            let columnX = layout.labelGutter + CGFloat(dayIndex(day)) * columnWidth
            ForEach(day.events) { placed in
                let laneWidth = columnWidth / CGFloat(placed.columns)
                let x = columnX + layout.eventLeading
                    + CGFloat(placed.column) * laneWidth
                let width = max(0, laneWidth - layout.eventWidthInset)
                eventBlock(placed.item)
                    .frame(width: width, height: layout.height(for: placed.item), alignment: .topLeading)
                    .offset(x: x, y: layout.offset(for: placed.item))
            }
        }
    }

    private func dayIndex(_ day: WeekAgenda.Day) -> Int {
        days.firstIndex { $0.dayOffset == day.dayOffset } ?? 0
    }

    private func eventBlock(_ item: AgendaItem) -> some View {
        Button { onOpenEvent(item) } label: {
            eventCard(item)
        }
        .buttonStyle(.plain)
        .focusRing(in: UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: theme.radiusSmall,
            topTrailingRadius: theme.radiusSmall
        ))
        .help("Abre o compromisso")
        .uniContextMenu(
            AgendaContextMenu.entries(for: item, store: store, anchor: anchor),
            store: store,
            onReveal: onRevealMessage
        )
    }

    private func eventCard(_ item: AgendaItem) -> some View {
        let color = tint(of: item.accountID)
        let tight = layout.isTight(for: item)

        return HStack(spacing: 0) {
            // Protótipo: `border-left: 2px solid c`.
            Rectangle()
                .fill(color)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: tight ? 0 : 2) {
                // O título completo, com reticências quando a coluna aperta —
                // é o que o protótipo faz com `text-overflow: ellipsis`, e é
                // por isso que a fixture não guarda um segundo título curto.
                Text(tight ? "\(item.title) · \(item.startLabel)" : item.title)
                    .font(theme.sans.font(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !tight {
                    Text("\(item.startLabel)–\(item.endLabel)")
                        .font(theme.mono.font(size: 9))
                        .foregroundStyle(color.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Protótipo: `padding: tight ? '0 6px' : '5px 7px'`.
            .padding(.horizontal, tight ? 6 : 7)
            .padding(.vertical, tight ? 0 : 5)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        // Protótipo: `soft(c, 15)`.
        .background(color.opacity(0.15))
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: theme.radiusSmall,
                topTrailingRadius: theme.radiusSmall
            )
        )
        .contentShape(Rectangle())
    }

    /// O traço de "agora", atravessando as sete colunas, com a pastilha do
    /// horário na calha. Protótipo: `nowWeekStyle` e `nowWeekPillStyle`.
    private var nowMarker: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: layout.labelGutter, height: 0)
                Rectangle()
                    .fill(SemanticColor.live(isDark: theme.isDark))
                    .frame(height: 2)
            }
            .frame(height: 0, alignment: .center)
            .offset(y: layout.offset(minuteOfDay: now))

            Text(Self.hourLabel(minuteOfDay: now))
                .font(theme.mono.font(size: 9.5, weight: .medium))
                .foregroundStyle(theme.onAccent.color)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(SemanticColor.live(isDark: theme.isDark))
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                // Protótipo: `left: 6px; top: now * 0.9 - 9` — os 9 são metade
                // da pastilha, que a deixa centrada no traço.
                .offset(x: 6, y: layout.offset(minuteOfDay: now) - 9)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Cor por conta

    /// A cor da caixa a que o compromisso pertence. Conta desconhecida cai no
    /// acento do tema: nada aqui presume quais contas existem.
    private func tint(of accountID: String) -> Color {
        store.account(accountID)
            .flatMap { TokenColor(css: $0.tint(isDark: theme.isDark))?.color }
            ?? theme.accent.color
    }

    /// "00:00", "09:00", … Protótipo: `fmt(min % 1440)`, que é o que faz a
    /// última linha da grade dizer 00:00 em vez de 24:00.
    public nonisolated static func hourLabel(minuteOfDay: Int) -> String {
        let wrapped = minuteOfDay % 1440
        return String(format: "%02d:%02d", wrapped / 60, wrapped % 60)
    }
}

#if os(macOS)
#Preview {
    let store = MailStore(source: InMemoryMailSource.fixtures)
    return WeekScreen(store: store, now: Fixtures.nowMinute, anchor: Fixtures.today)
        .environment(ThemeStore())
        .frame(width: 1440, height: 858)
        .task { await store.load() }
}
#endif

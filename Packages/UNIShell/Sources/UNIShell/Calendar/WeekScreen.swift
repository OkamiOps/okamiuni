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
    /// O recibo com "Desfazer" de "Tirar da agenda". Opcional no ambiente,
    /// como em toda superfície: harness e preview não precisam prover nada.
    @Environment(ActionReceipts.self) private var receipts: ActionReceipts?
    /// Os padrões da Agenda. Dois deles desenham **esta** grade: em que dia a
    /// semana começa e qual faixa do dia é horário de trabalho. Ausente (nos
    /// ensaios e em quem ainda não os injeta), vale o de sempre: segunda a
    /// domingo, sem realce.
    @Environment(CalendarPreferences.self) private var preferences: CalendarPreferences?
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
    /// Os blocos que a IA propõe para hoje — tracejados em accent, como no
    /// protótipo do Vidro. Vazio fora dele.
    var propostos: [PlanoDoDia.Bloco] = []
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
        propostos: [PlanoDoDia.Bloco] = [],
        onOpenEvent: @escaping (AgendaItem) -> Void = { _ in },
        onRevealMessage: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.layout = layout
        self.now = now ?? Self.minutesNow()
        self.anchor = anchor ?? Date.now
        self.focusOffset = focusOffset
        self.propostos = propostos
        self.onOpenEvent = onOpenEvent
        self.onRevealMessage = onRevealMessage
    }

    private static func minutesNow() -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private var days: [WeekAgenda.Day] {
        WeekAgenda.days(
            from: store.calendarAgenda, anchor: anchor, focusOffset: focusOffset,
            firstWeekday: preferences?.weekStart.rawValue ?? 2
        )
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
        let visibleDays = days
        let displaysNow = visibleDays.contains { $0.isToday }

        VStack(spacing: 0) {
            dayHeaderStrip(visibleDays)
            grid(days: visibleDays, showsNow: displaysNow)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Faixa dos dias

    /// Protótipo: `padding-left: 54px`, uma coluna por dia com
    /// `padding: 9px 12px 8px` e divisória à esquerda.
    ///
    /// A abreviação e o número ficam lado a lado, e hoje ganha o círculo cheio
    /// em accent — e a faixa não tem divisórias, que no protótipo não existem
    /// acima da grade. O número e o círculo saem do accent **do tema**, e por
    /// isso o mesmo desenho serve aos 28.
    private func dayHeaderStrip(_ days: [WeekAgenda.Day]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: layout.labelGutter, height: 0)
            ForEach(days) { day in
                VidroNumeroDoDia(
                    weekday: day.weekdayLabel.lowercased(),
                    numero: day.dayNumber, hoje: day.isToday
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - A grade

    private func grid(days: [WeekAgenda.Day], showsNow: Bool) -> some View {
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
                        columnBackgrounds(columnWidth: columnWidth, days: days)
                        hourLines
                        events(columnWidth: columnWidth, days: days)
                        if !propostos.isEmpty {
                            blocosPropostos(columnWidth: columnWidth, days: days)
                        }
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
    private func columnBackgrounds(
        columnWidth: CGFloat,
        days: [WeekAgenda.Day]
    ) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: layout.labelGutter)
            ForEach(days) { day in
                Rectangle()
                    // O realce de hoje é o acento a 5%, como no protótipo —
                    // `accentSoft` é opaco e no Vidro apagaria o gradiente.
                    .fill(
                        day.isToday
                            ? theme.accent.color.opacity(theme.isDark ? 0.07 : 0.05)
                            : Color.clear
                    )
                    .frame(width: columnWidth)
                    .hairline(theme.line2, edges: .leading)
            }
        }
        .frame(height: layout.totalHeight, alignment: .top)
        .overlay(alignment: .top) { workingHoursBand(columnWidth: columnWidth) }
    }

    /// A faixa de horário de trabalho, de Configurações ▸ Agendas.
    ///
    /// Uma lâmina só, atrás das linhas de hora e dos compromissos: o que ela
    /// faz é separar o dia útil das 23h da noite, e um retângulo por coluna
    /// desenharia sete vezes a mesma informação. Fora da calha de rótulos,
    /// para a hora continuar legível.
    @ViewBuilder
    private func workingHoursBand(columnWidth: CGFloat) -> some View {
        if let hours = preferences?.workingHours {
            let top = CGFloat(hours.startMinute) * layout.pointsPerMinute
            let height = CGFloat(hours.endMinute - hours.startMinute) * layout.pointsPerMinute
            Rectangle()
                .fill(theme.ink.color.opacity(theme.isDark ? 0.045 : 0.035))
                .frame(height: height)
                .padding(.leading, layout.labelGutter)
                .offset(y: top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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

    private func events(columnWidth: CGFloat, days: [WeekAgenda.Day]) -> some View {
        ForEach(days) { day in
            let columnX = layout.labelGutter + CGFloat(dayIndex(day, in: days)) * columnWidth
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

    private func dayIndex(_ day: WeekAgenda.Day, in days: [WeekAgenda.Day]) -> Int {
        days.firstIndex { $0.dayOffset == day.dayOffset } ?? 0
    }

    @ViewBuilder
    private func eventBlock(_ item: AgendaItem) -> some View {
        Button { onOpenEvent(item) } label: {
            vidroEventCard(item)
        }
        .buttonStyle(.plain)
        .focusRing(in: RoundedRectangle(cornerRadius: VidroEvento.radius))
        .help(item.isCancelled ? L10n.tr("Compromisso cancelado") : L10n.tr("Abre o compromisso"))
        .uniContextMenu(
            AgendaContextMenu.entries(for: item, store: store, anchor: anchor),
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

    /// O cartão do Vidro: retângulo translúcido na cor do calendário, canto de
    /// 8 nos quatro lados, título em 12 semibold e a hora em mono 10. Sem a
    /// barra à esquerda — no protótipo é o fundo que diz de que calendário é.
    private func vidroEventCard(_ item: AgendaItem) -> some View {
        let tight = layout.isTight(for: item)
        let tinta = VidroEvento.ink(item, in: store, theme: theme)
        let forma = RoundedRectangle(cornerRadius: VidroEvento.radius, style: .continuous)
        return VStack(alignment: .leading, spacing: 2) {
            CalendarEventChrome.title(item.title, cancelled: item.isCancelled)
                .font(theme.sans.font(size: 12, weight: .semibold))
                .foregroundStyle(tinta)
                .lineLimit(1)
                .truncationMode(.tail)
            if !tight {
                Text("\(item.startLabel)–\(item.endLabel)")
                    .font(theme.mono.font(size: 10))
                    .foregroundStyle(tinta.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 8)
        .padding(.vertical, tight ? 3 : 6)
        .background(VidroEvento.fill(item, in: store, theme: theme))
        .clipShape(forma)
        .overlay {
            forma.strokeBorder(
                CalendarEventChrome.border(cancelled: item.isCancelled, theme: theme),
                lineWidth: 1
            )
        }
        .contentShape(Rectangle())
    }

    /// Os blocos que a IA propôs para hoje: tracejados em accent, por cima da
    /// grade e **sem** clique — eles não existem na agenda ainda.
    private func blocosPropostos(
        columnWidth: CGFloat, days: [WeekAgenda.Day]
    ) -> some View {
        let hoje = days.firstIndex { $0.isToday }
        return ForEach(propostos) { bloco in
            if let hoje {
                let x = layout.labelGutter + CGFloat(hoje) * columnWidth + layout.eventLeading
                VStack(alignment: .leading, spacing: 2) {
                    Text(bloco.title)
                        .font(theme.sans.font(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(L10n.tr("\(MinuteFormat.clock(bloco.startMinute)) · proposto"))
                        .font(theme.mono.font(size: 10))
                        .opacity(0.75)
                        .lineLimit(1)
                }
                .foregroundStyle(theme.accentInk.color)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(theme.accent.color.opacity(theme.isDark ? 0.10 : 0.05))
                .clipShape(RoundedRectangle(cornerRadius: VidroEvento.radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: VidroEvento.radius, style: .continuous)
                        .strokeBorder(
                            theme.accentInk.color,
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                        )
                }
                .frame(
                    width: max(0, columnWidth - layout.eventWidthInset),
                    height: CGFloat(bloco.minutes) * layout.pointsPerMinute
                        - layout.eventHeightInset,
                    alignment: .topLeading
                )
                .offset(x: x, y: CGFloat(bloco.startMinute) * layout.pointsPerMinute)
                .allowsHitTesting(false)
                .accessibilityLabel(
                    L10n.tr("Proposto às \(MinuteFormat.clock(bloco.startMinute)), \(bloco.title)")
                )
            }
        }
    }

    /// O traço de "agora", atravessando as sete colunas, com a pastilha do
    /// horário na calha. Protótipo: `nowWeekStyle` e `nowWeekPillStyle`.
    private var nowMarker: some View {
        // O traço é o `nowLine` do tema — laranja no Vidro, o vermelho
        // semântico nos outros — e a calha ganha o ponto do protótipo no
        // lugar da pastilha com "HH:MM".
        let cor = theme.nowLine
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: layout.labelGutter, height: 0)
                Rectangle()
                    .fill(cor.color)
                    .frame(height: 2)
            }
            .frame(height: 0, alignment: .center)
            .offset(y: layout.offset(minuteOfDay: now))

            Circle()
                .fill(cor.color)
                .frame(width: 12, height: 12)
                .offset(x: layout.labelGutter - 10, y: layout.offset(minuteOfDay: now) - 6)
        }
        .allowsHitTesting(false)
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

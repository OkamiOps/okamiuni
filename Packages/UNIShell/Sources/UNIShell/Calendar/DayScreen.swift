import SwiftUI
import UNIDesign
import UNICore

/// A visão **Dia** da tela 02 (protótipo, linhas 1463–1497): a grade de um dia
/// só, mais a lateral de 250pt "Livre hoje".
public struct DayScreen: View {

    /// A régua do dia. **Diverge das outras duas de propósito**, e o protótipo
    /// é explícito: a trilha diária da caixa de entrada usa 0,78 pt/min na
    /// faixa 08:00–19:00; a grade da semana usa 0,9; esta usa **0,95** no dia
    /// inteiro, porque `top: min * 0.95` e `height: 1370px` (linhas 2364 e
    /// 1466). São três telas com três densidades, não um número esquecido.
    public struct Layout: Sendable {
        /// Protótipo: `min * 0.95`.
        public let pointsPerMinute: CGFloat

        /// Protótipo: `height: 1370px`. São 2pt a mais que 1440 × 0.95 = 1368.
        public let totalHeight: CGFloat = 1370

        /// Protótipo: `padding: 0 24px 40px 54px` no corpo e `left: 54px` nas
        /// linhas de hora — a mesma calha da grade da semana.
        public let labelGutter: CGFloat = 54

        /// Protótipo: `right: 24px` nas linhas de hora.
        public let trailingInset: CGFloat = 24

        /// Protótipo: `left: -50px; width: 40px` no rótulo, relativo à linha.
        public let labelWidth: CGFloat = 40
        public let labelInset: CGFloat = 50

        /// Onde a faixa dos cartões começa e termina. Protótipo: um contêiner
        /// absoluto em `left: 62px; right: 30px`, **dentro** do corpo que já
        /// tem `padding-left: 54px`… mas `position: absolute` ignora o padding
        /// do pai: os 62 e os 30 são da borda do corpo.
        ///
        /// Ou seja, os cartões começam 8pt depois da linha de hora e terminam
        /// 6pt antes dela. Não é arredondamento: é a folga que separa o cartão
        /// do rótulo à esquerda e da borda da lateral à direita.
        public let eventLeading: CGFloat = 62
        public let eventTrailing: CGFloat = 30

        /// Protótipo: `width: calc(100/cols % - 4px)`.
        public let eventWidthInset: CGFloat = 4

        /// Protótipo: `height: (e - s) * 0.95 - 4`.
        public let eventHeightInset: CGFloat = 4

        /// Protótipo: `tight = h < 52`. Mais alto que os 40 da semana porque o
        /// cartão do dia é maior: título em 13 e meta em 10, contra 11 e 9.
        public let tightHeight: CGFloat = 52

        /// Protótipo: a lateral tem `width: 250px`.
        public let sidebarWidth: CGFloat = 250

        public init(pointsPerMinute: CGFloat = 0.95) {
            self.pointsPerMinute = pointsPerMinute
        }

        public func offset(minuteOfDay: Int) -> CGFloat {
            CGFloat(minuteOfDay) * pointsPerMinute
        }

        public func offset(for item: AgendaItem) -> CGFloat {
            offset(minuteOfDay: item.startMinute)
        }

        public func height(for item: AgendaItem) -> CGFloat {
            CGFloat(item.durationMinutes) * pointsPerMinute - eventHeightInset
        }

        public func isTight(for item: AgendaItem) -> Bool {
            height(for: item) < tightHeight
        }

        /// Largura da faixa em que os cartões vivem, dada a largura da grade.
        public func eventTrackWidth(gridWidth: CGFloat) -> CGFloat {
            max(0, gridWidth - eventLeading - eventTrailing)
        }

        /// Protótipo: `el.scrollTop = Math.max(0, now * 0.95 - 150)`.
        public func scrollTarget(now: Int) -> CGFloat {
            max(0, CGFloat(now) * pointsPerMinute - 150)
        }
    }

    @Environment(\.theme) private var theme
    /// O recibo com "Desfazer" de "Tirar da agenda". Opcional no ambiente,
    /// como em toda superfície: harness e preview não precisam prover nada.
    @Environment(ActionReceipts.self) private var receipts: ActionReceipts?
    @Environment(\.displayScale) private var displayScale

    let store: MailStore
    let layout: Layout
    /// Minutos desde a meia-noite, injetado para teste.
    let now: Int
    let anchor: Date
    /// Qual dia está no ar, em dias a partir de `anchor`.
    let dayOffset: Int
    let onOpenEvent: (AgendaItem) -> Void
    /// "Ir para o email de origem", do menu de contexto do cartão. Recebe o id
    /// da mensagem; quem sabe levar o leitor até ela é o `InboxScreen`.
    let onRevealMessage: (String) -> Void

    public init(
        store: MailStore,
        layout: Layout = Layout(),
        now: Int,
        anchor: Date,
        dayOffset: Int,
        onOpenEvent: @escaping (AgendaItem) -> Void = { _ in },
        onRevealMessage: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.layout = layout
        self.now = now
        self.anchor = anchor
        self.dayOffset = dayOffset
        self.onOpenEvent = onOpenEvent
        self.onRevealMessage = onRevealMessage
    }

    private var items: [AgendaItem] {
        WeekAgenda.items(on: dayOffset, in: store.calendarAgenda)
    }

    /// O traço de "agora" só existe no dia de hoje. Protótipo:
    /// `nowOnThisDay: st.dayW === 4 && st.dayD === 1` — a célula do dia 25.
    private var showsNow: Bool { dayOffset == 0 }

    public var body: some View {
        HStack(spacing: 0) {
            grid
            freeTimeSidebar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - A grade

    private static let scrollAnchorID = "day.scroll.now"

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        hourLines
                        events(gridWidth: geometry.size.width)
                        if showsNow { nowMarker }
                        scrollAnchor
                    }
                    .frame(
                        width: geometry.size.width, height: layout.totalHeight,
                        alignment: .topLeading
                    )
                }
                // Protótipo: `padding-bottom: 40px` — a folga que impede o
                // último cartão de encostar no fim da rolagem.
                .frame(height: layout.totalHeight + 40)
            }
            .onAppear { proxy.scrollTo(Self.scrollAnchorID, anchor: .top) }
            .onChange(of: dayOffset) { _, _ in
                proxy.scrollTo(Self.scrollAnchorID, anchor: .top)
            }
        }
        .frame(maxWidth: .infinity)
        .background(theme.surface.color)
    }

    /// Ver `WeekScreen.scrollAnchor`: o alvo precisa ser altura de verdade, não
    /// `.offset`, senão `scrollTo` não o encontra e a grade abre na meia-noite.
    private var scrollAnchor: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: layout.scrollTarget(now: now))
            Color.clear.frame(height: 1).id(Self.scrollAnchorID)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }

    /// 25 linhas, de 00:00 a 24:00, com o rótulo na calha.
    /// Protótipo: `dayHours` (linha 2364).
    private var hourLines: some View {
        ForEach(0...24, id: \.self) { hour in
            HStack(spacing: 0) {
                Text(MinuteFormat.clock(hour * 60))
                    .font(theme.mono.font(size: 9.5))
                    .foregroundStyle(theme.ink4.color)
                    .frame(width: layout.labelWidth, alignment: .trailing)
                    .padding(.leading, layout.labelGutter - layout.labelInset)
                Spacer(minLength: layout.labelInset - layout.labelWidth)
                Rectangle()
                    .fill(theme.line2.color)
                    .frame(height: Hairline.thickness(displayScale))
                    .padding(.trailing, layout.trailingInset)
            }
            .frame(height: 0, alignment: .center)
            .offset(y: layout.offset(minuteOfDay: hour * 60))
        }
    }

    private func events(gridWidth: CGFloat) -> some View {
        let trackWidth = layout.eventTrackWidth(gridWidth: gridWidth)
        return ForEach(WeekAgenda.lanes(items)) { placed in
            let laneWidth = trackWidth / CGFloat(placed.columns)
            eventCard(placed.item)
                .frame(
                    width: max(0, laneWidth - layout.eventWidthInset),
                    height: layout.height(for: placed.item),
                    alignment: .topLeading
                )
                .offset(
                    x: layout.eventLeading + CGFloat(placed.column) * laneWidth,
                    y: layout.offset(for: placed.item)
                )
                .zIndex(Double(2 + placed.column))
        }
    }

    /// Protótipo: `e.style` (linhas 2396–2401), com `border-left: 3px` — um a
    /// mais que os 2 da semana, porque o cartão do dia é largo o bastante para
    /// a faixa de cor ler como faixa.
    private func eventCard(_ item: AgendaItem) -> some View {
        let swatch = CalendarTint.token(of: item, in: store, theme: theme)
        let tight = layout.isTight(for: item)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: theme.radiusSmall,
            topTrailingRadius: theme.radiusSmall
        )

        let cancelled = item.isCancelled
        return Button { onOpenEvent(item) } label: {
            HStack(spacing: 0) {
                Rectangle().fill(CalendarEventChrome.bar(swatch, cancelled: cancelled, theme: theme)).frame(width: 3)
                VStack(alignment: .leading, spacing: tight ? 0 : 3) {
                    CalendarEventChrome.title(
                        tight ? "\(item.title) · \(item.rangeLabel)" : item.title,
                        cancelled: cancelled
                    )
                        .font(theme.sans.font(size: 13, weight: .semibold))
                        .foregroundStyle(CalendarEventChrome.ink(swatch, cancelled: cancelled, theme: theme))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !tight {
                        Text("\(item.startLabel)–\(item.endLabel) · \(hostLabel(item))")
                            .font(theme.mono.font(size: 10))
                            .foregroundStyle(CalendarEventChrome.ink(swatch, cancelled: cancelled, theme: theme).opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Protótipo: `padding: tight ? '0 10px' : '9px 12px'`.
                .padding(.horizontal, tight ? 10 : 12)
                .padding(.vertical, tight ? 0 : 9)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .background(CalendarEventChrome.fill(swatch, cancelled: cancelled, theme: theme))
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(CalendarEventChrome.border(cancelled: cancelled, theme: theme), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(in: shape)
        // Protótipo: `opacity: 0.5` no que já acabou, e só quando o dia no ar é
        // hoje — num outro dia "já passou" não quer dizer nada.
        .opacity(showsNow && item.endMinute < now ? 0.5 : 1)
        .help(item.isCancelled ? "Compromisso cancelado" : "Abre o compromisso")
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

    /// O host da conta, como o protótipo escreve (`acc: ACC[e.a].host`). Conta
    /// desconhecida cai no próprio identificador em vez de sumir da linha.
    private func hostLabel(_ item: AgendaItem) -> String {
        store.account(item.accountID)?.host ?? item.accountID
    }

    /// Protótipo: `nowDayStyle` e `nowDayPillStyle` (linhas 2324–2325).
    private var nowMarker: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: layout.labelGutter, height: 0)
                Rectangle()
                    .fill(theme.live.color)
                    .frame(height: 2)
                    .padding(.trailing, layout.trailingInset)
            }
            .frame(height: 0, alignment: .center)
            .offset(y: layout.offset(minuteOfDay: now))

            Text(MinuteFormat.clock(now))
                .font(theme.mono.font(size: 9.5, weight: .medium))
                .foregroundStyle(theme.onAccent.color)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(theme.live.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                // Protótipo: `left: 0; top: now * 0.95 - 9` — os 9 são metade
                // da pastilha, que a deixa centrada no traço.
                .offset(y: layout.offset(minuteOfDay: now) - 9)
        }
        .allowsHitTesting(false)
        .zIndex(50)
    }

    // MARK: - "Livre hoje"

    /// A lateral de 250pt (protótipo, linhas 1488–1496).
    ///
    /// Ela é da visão **Dia** e só dela: na Semana e no Mês o protótipo não a
    /// desenha, e faz sentido — "onde eu encaixo uma reunião" é pergunta de um
    /// dia, e sete respostas lado a lado não caberiam em 250pt.
    private var freeTimeSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(showsNow ? "Livre hoje" : "Livre neste dia")
                .capsLabel(size: 9.5)
                .padding(.bottom, 10)

            ForEach(DayAgenda.gaps(in: items)) { gap in
                HStack(spacing: 8) {
                    Text(gap.rangeLabel)
                        .font(theme.mono.font(size: 11))
                    Spacer(minLength: 0)
                    Text(gap.lengthLabel)
                        .font(theme.sans.font(size: 12))
                }
                .foregroundStyle(theme.ink2.color)
                .padding(.vertical, 7)
                .hairline(theme.line2, edges: .bottom)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Livre das \(gap.rangeLabel), \(gap.lengthLabel)")
            }

            Spacer(minLength: 0)
        }
        .frame(width: layout.sidebarWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .frame(width: layout.sidebarWidth + 32)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .leading)
    }
}

import SwiftUI
import UNIDesign
import UNICore

public struct AgendaRail: View {
    /// Apelido da largura canônica, que mora em `PaneLayout`.
    public static let width: CGFloat = PaneLayout.agendaWidth

    /// Converte minutos do dia em pontos na trilha.
    ///
    /// Faixa: 00:00 a 24:00 — o dia inteiro, rolável, como a Dia/Semana já
    /// eram. Antes era 480 (08:00) a 1140 (19:00): o dono conectou uma conta
    /// real e viu compromissos depois das 19h somem da trilha — "o dia não
    /// acaba às 18" foi a fala dele. `pointsPerMinute` continua 0,78: o que
    /// muda é só onde a régua começa e termina, não a densidade dela.
    public struct Layout: Sendable {
        public let pointsPerMinute: CGFloat

        /// Largura da calha dos rótulos de hora.
        ///
        /// O protótipo declara `width: 26px` no span, mas escreve `fmt(min)`
        /// dentro dele — "08:00", cinco caracteres. Em mono 9pt isso mede ~27pt
        /// e transborda os 26 na própria página; o span só não trunca porque
        /// tem os 6px de `gap` livres à direita. Aqui a calha recebe os 30pt que
        /// o texto pede, e a diferença sai da largura do cartão: `eventLeading`
        /// é derivado da calha, então o cartão continua começando logo depois
        /// dela. É medida de conteúdo, não de painel — não muda com a janela.
        public let labelGutter: CGFloat = 30

        /// Folga entre a calha e a linha da hora.
        /// Protótipo: `gap: 6px` na linha da hora.
        public let gutterGap: CGFloat = 6

        /// Recuo à direita dos cartões. Protótipo: `right: 2px`.
        public let eventTrailing: CGFloat = 2

        public init(pointsPerMinute: CGFloat = 0.78) {
            self.pointsPerMinute = pointsPerMinute
        }

        /// Onde os cartões de evento começam: sempre depois da calha mais a
        /// folga. No protótipo isso dá `left: 32px` (26 + 6); com a calha de
        /// 30pt que "08:00" exige, dá 36. Deixar isto menor que `labelGutter`
        /// faz o cartão cobrir o rótulo da hora, que foi o defeito que esta
        /// constante existe para impedir.
        public var eventLeading: CGFloat { labelGutter + gutterGap }

        /// Onde o marcador de "agora" começa. Protótipo: `nowStyle … left: 26px`,
        /// que é a largura da calha — ele encosta nela sem atravessá-la, e
        /// acompanha a calha quando ela muda.
        public var nowMarkerLeading: CGFloat { labelGutter }

        public var totalHeight: CGFloat {
            1_440 * pointsPerMinute  // o dia inteiro, 00:00 a 24:00
        }

        public func offset(for item: AgendaItem) -> CGFloat {
            CGFloat(item.startMinute) * pointsPerMinute
        }

        /// Onde a rolagem inicial deixa a trilha: a manhã (~08:00) visível,
        /// não a meia-noite. Mesma ideia do `scrollTarget` de `DayScreen`/
        /// `WeekScreen`, mas fixa em 08:00 em vez de seguir "agora" — a trilha
        /// é o resumo do dia inteiro, e abrir nele é sempre útil, esteja
        /// "agora" de manhã, de tarde ou de madrugada.
        public var initialScrollTarget: CGFloat {
            480 * pointsPerMinute
        }

        public func height(for item: AgendaItem) -> CGFloat {
            let computed = CGFloat(item.durationMinutes) * pointsPerMinute - 3
            // Altura mínima 42 para garantir clicabilidade em modo "tight"
            return max(42, computed)
        }

        public func isTight(for item: AgendaItem) -> Bool {
            let computed = CGFloat(item.durationMinutes) * pointsPerMinute - 3
            return computed < 42
        }
    }

    @Environment(\.theme) private var theme
    /// O recibo com "Desfazer" de "Tirar da agenda". Opcional no ambiente,
    /// como em toda superfície: harness e preview não precisam prover nada.
    @Environment(ActionReceipts.self) private var receipts: ActionReceipts?
    @Environment(\.displayScale) private var displayScale
    let store: MailStore
    let layout: Layout
    let now: Int  // minutos desde meia-noite, injetado para teste
    let headerDate: Date  // injetado para teste; default é hoje

    /// A largura resolvida que a janela concedeu.
    let railWidth: CGFloat

    /// Clicar num cartão abre a janela 04. Protótipo: cada evento da trilha tem
    /// `onOpen: () => this.openEvent(...)`.
    let onOpenEvent: (AgendaItem) -> Void

    /// "Ir para o email de origem", do menu de contexto do cartão. Recebe o id
    /// da mensagem; quem sabe levar o leitor até ela é o `InboxScreen`.
    let onRevealMessage: (String) -> Void

    /// A trilha desenha a própria seção "Vindo do email"? O dashboard diz
    /// `false` porque põe as PENDÊNCIAS dele — com estado vazio, que esta não
    /// tem — logo abaixo da trilha, e duas seções iguais na mesma coluna seria
    /// a mesma informação dita duas vezes.
    let showsPending: Bool

    /// O fundo da coluna. A Caixa a põe sobre `surface2`; o mockup do
    /// dashboard (`.rail { background: var(--surface) }`) a põe sobre
    /// `surface`. É token dos dois lados — nenhuma cor literal entra aqui.
    let background: KeyPath<Theme, TokenColor>

    /// A trilha corta em **fronteira de cartão** quando a altura não dá para
    /// tudo?
    ///
    /// Na Caixa, `false`: a trilha ocupa a janela inteira e a rolagem é a
    /// resposta natural. No dashboard ela divide a coluna com as PENDÊNCIAS, e
    /// a borda de baixo caía no meio de um cartão — "14:00 Revisão do
    /// contrato" pela metade, com PENDÊNCIAS colada embaixo. Meio cartão lê
    /// como tela quebrada, não como "tem mais aqui".
    ///
    /// Com `true` a região rolável mede `Self.clipHeight(...)`: a maior altura
    /// que termina onde uma linha termina. O que sobra fica como folga acima
    /// das PENDÊNCIAS, que continuam ancoradas no rodapé da coluna.
    let clipsToRowBoundary: Bool

    /// Altura de cada linha da trilha, medida no desenho. Só é preenchida com
    /// `clipsToRowBoundary`.
    @State private var rowHeights: [String: CGFloat] = [:]
    /// A altura que a coluna ofereceu à região rolável.
    @State private var availableTrackHeight: CGFloat = 0

    public init(
        store: MailStore,
        layout: Layout = Layout(),
        now: Int? = nil,
        headerDate: Date? = nil,
        width: CGFloat = PaneLayout.agendaWidth,
        showsPending: Bool = true,
        background: KeyPath<Theme, TokenColor> = \.surface2,
        clipsToRowBoundary: Bool = false,
        onOpenEvent: @escaping (AgendaItem) -> Void = { _ in },
        onRevealMessage: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.layout = layout
        self.now = now ?? Self.minutesNow()
        self.headerDate = headerDate ?? Date.now
        self.railWidth = width
        self.showsPending = showsPending
        self.background = background
        self.clipsToRowBoundary = clipsToRowBoundary
        self.onOpenEvent = onOpenEvent
        self.onRevealMessage = onRevealMessage
    }

    private static func minutesNow() -> Int {
        let d = Date()
        return d.hour * 60 + d.minute
    }

    /// Só o dia de hoje, na conta selecionada. Desde que a semana entrou,
    /// `store.agenda` carrega os sete dias numa lista só — é isso que deixa a
    /// janela 04 achar um compromisso de quarta pelo `id`. A trilha mostra um
    /// dia, então filtra por dia; e como toda superfície de agenda,
    /// `store.visibleAgenda` já filtra por conta antes disso — sem isto a
    /// trilha continuaria citando compromissos de outra caixa depois de
    /// clicar numa conta na barra lateral (`MessageStore.swift:98-103`).
    ///
    /// `internal`, não `private`: `AgendaRailTests` precisa ler isto para
    /// provar o filtro sem depender de renderizar pixel.
    var todayItems: [AgendaItem] {
        WeekAgenda.items(on: 0, in: store.visibleAgenda)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            track
            if showsPending, !store.visiblePendingItems.isEmpty {
                pendingSection
            }
        }
        .frame(width: railWidth)
        .background(theme[keyPath: background].color)
        .agendaUndoBand(store: store)
        .hairline(theme.line, edges: .leading)
    }

    /// `.rail-scroll` — a trilha, cortada em fronteira de linha quando quem
    /// hospeda pediu (ver `clipsToRowBoundary`).
    @ViewBuilder
    private var track: some View {
        if clipsToRowBoundary {
            ZStack(alignment: .top) {
                // Mede o que a coluna ofereceu **sem** depender do que a
                // trilha decidir ocupar: pôr o `onGeometryChange` na própria
                // `ScrollView` faria a altura medir a si mesma.
                Color.clear
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        availableTrackHeight = height
                    }
                trackScroll
                    .frame(height: clippedTrackHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            trackScroll
        }
    }

    private var trackScroll: some View {
        ScrollView {
            trackRows
                .padding(.horizontal, 14)
                .padding(.top, Self.trackTopPadding)
                .padding(.bottom, 16)
        }
    }

    /// `VStack` com corte em fronteira, `LazyVStack` sem ele: a linha que a
    /// preguiça não desenhou é a linha que não sabe dizer a própria altura, e
    /// sem todas as alturas o corte volta a cair no meio de um cartão. A Caixa
    /// continua preguiçosa, byte a byte como antes.
    @ViewBuilder
    private var trackRows: some View {
        if clipsToRowBoundary {
            VStack(alignment: .leading, spacing: 0) { trackContent }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) { trackContent }
        }
    }

    @ViewBuilder
    private var trackContent: some View {
        if todayItems.isEmpty {
            emptyDay
        } else {
            ForEach(Self.dayRows(items: todayItems, now: now)) { row in
                Group {
                    switch row {
                    case .period(let name):
                        periodLabel(name)
                    case .now:
                        nowRule
                    case .item(let item):
                        eventBlock(item)
                            .padding(.bottom, 10)
                    }
                }
                .measuringRailRow(row.id, when: clipsToRowBoundary) { id, height in
                    rowHeights[id] = height
                }
            }
        }
    }

    /// A altura da região rolável: a maior que termina onde uma linha termina.
    private var clippedTrackHeight: CGFloat {
        let rows = Self.dayRows(items: todayItems, now: now).map { row in
            ClipRow(height: rowHeights[row.id] ?? 0, isEvent: row.isEvent)
        }
        return Self.clipHeight(
            rows: rows,
            leading: Self.trackTopPadding,
            available: availableTrackHeight
        )
    }

    /// `padding(.top, 12)` do conteúdo da trilha. O corte tem de contá-lo:
    /// ele vem antes da primeira linha.
    nonisolated static let trackTopPadding: CGFloat = 12

    /// Uma linha da trilha, para a conta do corte.
    nonisolated struct ClipRow: Equatable, Sendable {
        let height: CGFloat
        /// Cartão de evento (`true`) ou rótulo de período / régua do "agora".
        let isEvent: Bool

        init(height: CGFloat, isEvent: Bool) {
            self.height = height
            self.isEvent = isEvent
        }
    }

    /// A maior altura ≤ `available` que **termina onde uma linha termina**.
    ///
    /// Regras, nesta ordem:
    ///
    /// 1. o maior prefixo de linhas que cabe;
    /// 2. se esse prefixo termina em rótulo de período ou na régua do "agora",
    ///    os finais assim são descartados — um "TARDE" sem nada embaixo é uma
    ///    promessa que a coluna não cumpre;
    /// 3. se nem a primeira linha cabe (janela baixa demais para um cartão), a
    ///    trilha fica com o que tem: não há altura sem corte, e sumir com a
    ///    agenda inteira seria pior do que a borda.
    ///
    /// Alturas ainda não medidas valem 0 e não travam a conta: no primeiro
    /// quadro a trilha ocupa tudo, e assenta no seguinte.
    nonisolated static func clipHeight(
        rows: [ClipRow], leading: CGFloat, available: CGFloat
    ) -> CGFloat {
        guard available > 0 else { return 0 }
        let espaco = available - leading
        guard espaco > 0 else { return available }

        var cabem: [ClipRow] = []
        var soma: CGFloat = 0
        for row in rows {
            guard soma + row.height <= espaco else { break }
            soma += row.height
            cabem.append(row)
        }
        // Tudo coube: a trilha fica com a coluna inteira, sem folga inventada.
        if cabem.count == rows.count { return available }

        while let ultima = cabem.last, !ultima.isEvent {
            soma -= ultima.height
            cabem.removeLast()
        }
        guard !cabem.isEmpty else { return available }
        return leading + soma
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agenda de hoje")
                .font(theme.serif.font(size: 16, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Text(Self.headerDateString(headerDate))
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink2.color)
                .lineLimit(1)
            nextUpLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .hairline(theme.line2, edges: .bottom)
    }

    private var nextUpLine: some View {
        let label = Self.nextUpLabel(for: todayItems, now: now)
        let live = label.hasPrefix("agora:")
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(live ? liveColor() : theme.ink4.color)
                .frame(width: 6, height: 6)
                .offset(y: 1)
            Text(label)
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(live ? theme.ink.color : theme.ink2.color)
                .lineLimit(2)
        }
        .accessibilityLabel(label)
    }

    private var emptyDay: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dia livre")
                .font(theme.serif.font(size: 15, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Text("Nenhum compromisso nesta caixa.")
                .font(theme.sans.font(size: 12))
                .foregroundStyle(theme.ink3.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
        .padding(.horizontal, 2)
    }

    private func periodLabel(_ name: String) -> some View {
        Text(name)
            .font(theme.mono.font(size: 9, weight: .medium))
            .tracking(theme.capsTracking(at: 9))
            .textCase(.uppercase)
            .foregroundStyle(theme.ink4.color)
            .padding(.top, 6)
            .padding(.bottom, 8)
    }

    private var nowRule: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(liveColor().opacity(0.55))
                .frame(height: 1)
            Text("agora")
                .font(theme.mono.font(size: 8.5, weight: .medium))
                .tracking(theme.capsTracking(at: 8.5))
                .textCase(.uppercase)
                .foregroundStyle(liveColor())
            Rectangle()
                .fill(liveColor().opacity(0.55))
                .frame(height: 1)
        }
        .padding(.vertical, 8)
        .padding(.bottom, 4)
        .accessibilityLabel("Agora")
    }

    private func liveColor() -> Color {
        theme.live.color
    }

    private func eventBlock(_ item: AgendaItem) -> some View {
        Button { onOpenEvent(item) } label: {
            eventCard(item)
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusLarge)
        .help(item.isCancelled ? "Compromisso cancelado" : "Abre o compromisso")
        // O mesmo menu das três visões da agenda. A trilha mostra sempre
        // hoje, então o dia do compromisso é o do cabeçalho.
        .uniContextMenu(
            AgendaContextMenu.entries(for: item, store: store, anchor: headerDate),
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

    private func eventCard(_ item: AgendaItem) -> some View {
        let tint = CalendarTint.token(of: item, in: store, theme: theme)
        let cancelled = item.isCancelled
        let running = !cancelled && now >= item.startMinute && now < item.endMinute
        let past = !cancelled && item.endMinute <= now
        let shape = RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous)
        let ink = CalendarEventChrome.ink(tint, cancelled: cancelled, theme: theme)
        return HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(CalendarEventChrome.bar(tint, cancelled: cancelled, theme: theme))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.startLabel)
                        .font(theme.mono.font(size: 15, weight: .medium))
                        .foregroundStyle(cancelled ? theme.ink4.color : theme.ink.color)
                    if running {
                        Text("Agora")
                            .font(theme.mono.font(size: 8, weight: .medium))
                            .tracking(theme.capsTracking(at: 8))
                            .textCase(.uppercase)
                            .foregroundStyle(liveColor())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(liveColor().opacity(theme.isDark ? 0.2 : 0.1), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    Text(cancelled ? "Cancelado" : item.durationLabel)
                        .font(theme.mono.font(size: 9, weight: .medium))
                        .tracking(theme.capsTracking(at: 9))
                        .textCase(.uppercase)
                        .foregroundStyle(cancelled ? theme.ink4.color : theme.ink3.color)
                }
                CalendarEventChrome.title(item.title, cancelled: cancelled)
                    .font(theme.sans.font(size: 13.5, weight: .semibold))
                    .foregroundStyle(cancelled ? theme.ink4.color : theme.ink.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let meta = Self.metaLine(for: item, host: store.account(item.accountID)?.host) {
                    Text(meta)
                        .font(theme.sans.font(size: 11))
                        .foregroundStyle(cancelled ? theme.ink4.color : ink.opacity(0.78))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(CalendarEventChrome.fill(tint, cancelled: cancelled, theme: theme))
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                cancelled
                    ? CalendarEventChrome.border(cancelled: true, theme: theme)
                    : (tint ?? theme.accent).color.opacity(theme.isDark ? 0.35 : 0.22),
                lineWidth: Hairline.thickness(displayScale)
            )
        }
        .contentShape(Rectangle())
        .opacity(past ? 0.55 : (cancelled ? 0.88 : 1))
    }

    /// `internal`, não `private`: `AgendaRailTests` precisa renderizar isto
    /// isoladamente para medir a folga entre os itens, sem o ruído da trilha
    /// de horas acima.
    var pendingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Vindo do email")
                .font(theme.mono.font(size: 9.5))
                .tracking(theme.capsTracking(at: 9.5))
                .textCase(.uppercase)
                .foregroundStyle(theme.ink4.color)
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .padding(.bottom, 9)

            // O `.padding(.bottom, 15)` tem de envolver a lista inteira, não o
            // `ForEach`: um modificador aplicado a um `ForEach` vale **por
            // elemento** no SwiftUI, não uma vez. Com dois itens isso somava
            // 15pt de folga extra a cada um — a distância entre "Confirmar
            // call…" e "Renovar domínio…" media 23pt em vez dos 8pt do
            // protótipo (`4px` de cada item + os `15px` da seção, uma vez só).
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.visiblePendingItems, id: \.id) { item in
                    let tint = store.account(item.accountID)
                        .flatMap { TokenColor(css: theme.isDark ? $0.tintDarkHex : $0.tintLightHex) } ?? theme.ink2

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(tint.color)
                            .frame(width: 5, height: 5)
                            .padding(.top, 2)
                        Text(item.text)
                            .font(theme.sans.font(size: 11.5))
                            .lineSpacing(5.175)  // line-height 1.45 × 11.5 − 11.5 = 5.175
                            .foregroundStyle(theme.ink2.color)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
            .padding(.bottom, 15)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface2.color)
        .hairline(theme.line2, edges: .top)
    }

    /// Rótulo dinâmico para o próximo compromisso.
    /// Delega para `AgendaSummary` que é pura (sem isolamento de ator).
    public nonisolated static func nextUpLabel(for items: [AgendaItem], now: Int) -> String {
        AgendaSummary.nextUpLabel(for: items, now: now)
    }

    /// Parte o dia em períodos e põe o "agora" no vão entre o que já passou
    /// e o que ainda vem — senão a trilha é só uma lista de cartões.
    nonisolated static func dayRows(items: [AgendaItem], now: Int) -> [RailRow] {
        let sorted = items.sorted { $0.startMinute < $1.startMinute }
        var rows: [RailRow] = []
        var lastPeriod: String?
        var previous: AgendaItem?
        for item in sorted {
            if let previous, previous.endMinute <= now, item.startMinute > now {
                rows.append(.now)
            }
            let period = periodName(for: item.startMinute)
            if lastPeriod != period {
                lastPeriod = period
                rows.append(.period(period))
            }
            rows.append(.item(item))
            previous = item
        }
        return rows
    }

    nonisolated static func periodName(for minute: Int) -> String {
        switch minute {
        case ..<360: "Madrugada"
        case ..<720: "Manhã"
        case ..<1080: "Tarde"
        default: "Noite"
        }
    }

    /// Local, sala ou host — o que couber numa linha, sem repetir o horário
    /// que o cartão já escreve em cima.
    nonisolated static func metaLine(for item: AgendaItem, host: String?) -> String? {
        if item.isCancelled { return nil }
        var parts: [String] = []
        if let place = item.detail?.place,
           place != EventPlace.semLocal,
           !place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(place)
        }
        if let room = roomLabel(for: item.detail) {
            parts.append(room)
        }
        if parts.isEmpty, let host, !host.isEmpty {
            parts.append(host)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    nonisolated static func roomLabel(for detail: EventDetail?) -> String? {
        guard let link = detail?.meetingLink ?? detail?.link,
              let host = URL(string: link)?.host()?.lowercased()
        else { return nil }
        if host == "meet.google.com" || host.hasSuffix(".meet.google.com") { return "Google Meet" }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") { return "Zoom" }
        if host.contains("teams.microsoft.com") || host.contains("teams.live.com") { return "Teams" }
        if host.contains("meeting.zoho.com") || host.contains("meet.zoho.com") { return "Zoho Meeting" }
        if host == "webex.com" || host.hasSuffix(".webex.com") { return "Webex" }
        if host == "whereby.com" || host.hasSuffix(".whereby.com") { return "Whereby" }
        if host == "meet.jit.si" || host.hasSuffix(".meet.jit.si") { return "Jitsi" }
        return "Videoconferência"
    }

    /// O rótulo da calha das horas: "08:00", "09:00", …
    /// Protótipo: `label: fmt(min)`, com
    /// `fmt = (m) => pad(floor(m / 60)) + ':' + pad(m % 60)`.
    public nonisolated static func hourLabel(minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    /// Formata a data do cabeçalho: "Terça-feira, 25 de agosto"
    public nonisolated static func headerDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEEE, d 'de' MMMM"
        let result = formatter.string(from: date)
        // Capitalizar a primeira letra do dia da semana
        return result.prefix(1).uppercased() + result.dropFirst()
    }
}

// MARK: - Helpers

extension Date {
    fileprivate var hour: Int {
        Calendar.current.component(.hour, from: self)
    }

    fileprivate var minute: Int {
        Calendar.current.component(.minute, from: self)
    }
}

/// As linhas da trilha de hoje: período, compromisso, e o "agora" no vão.
enum RailRow: Equatable, Identifiable {
    case period(String)
    case item(AgendaItem)
    case now

    var id: String {
        switch self {
        case .period(let name): "period-\(name)"
        case .item(let item): "item-\(item.id)"
        case .now: "now"
        }
    }

    /// Cartão de evento? Rótulo de período e régua do "agora" não são: uma
    /// trilha que termina num deles anuncia o que não mostra.
    var isEvent: Bool {
        if case .item = self { return true }
        return false
    }
}

/// Mede a altura de uma linha da trilha, e só quando alguém pediu.
///
/// Sem o `when` a Caixa pagaria por uma medida que não usa — e, pior, os
/// retratos dela passariam a depender de um segundo passe de layout.
private struct RailRowMeasure: ViewModifier {
    let id: String
    let active: Bool
    let report: (String, CGFloat) -> Void

    func body(content: Content) -> some View {
        if active {
            content.onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                report(id, height)
            }
        } else {
            content
        }
    }
}

extension View {
    fileprivate func measuringRailRow(
        _ id: String, when active: Bool, report: @escaping (String, CGFloat) -> Void
    ) -> some View {
        modifier(RailRowMeasure(id: id, active: active, report: report))
    }
}

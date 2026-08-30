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

    public init(
        store: MailStore,
        layout: Layout = Layout(),
        now: Int? = nil,
        headerDate: Date? = nil,
        width: CGFloat = PaneLayout.agendaWidth,
        onOpenEvent: @escaping (AgendaItem) -> Void = { _ in },
        onRevealMessage: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.layout = layout
        self.now = now ?? Self.minutesNow()
        self.headerDate = headerDate ?? Date.now
        self.railWidth = width
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if todayItems.isEmpty {
                        Text("Nenhum compromisso hoje.")
                            .font(theme.sans.font(size: 12))
                            .foregroundStyle(theme.ink3.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(todayItems) { item in
                            eventBlock(item)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            pendingSection
        }
        .frame(width: railWidth)
        .background(theme.surface2.color)
        .agendaUndoBand(store: store)
        .hairline(theme.line, edges: .leading)
    }

    private static let scrollAnchorID = "agendaRail.scroll.morning"

    /// Ver `DayScreen.scrollAnchor`: o alvo precisa ser altura de verdade,
    /// não `.offset`, senão `scrollTo` não o encontra e a trilha abre na
    /// meia-noite em vez das 08:00.
    private var scrollAnchor: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: layout.initialScrollTarget)
            Color.clear.frame(height: 1).id(Self.scrollAnchorID)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Agenda de hoje")
                .font(theme.serif.font(size: 15.5, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            Text("\(headerDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) · \(todayItems.count) \(todayItems.count == 1 ? "compromisso" : "compromissos")")
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink2.color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Protótipo: `padding: 12px 16px 11px` no cabeçalho da trilha.
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 11)
        .hairline(theme.line2, edges: .bottom)
    }

    /// Uma linha por hora, cada uma posicionada pelo minuto do dia — como o
    /// protótipo, que usa `position: absolute; top: (min - 480) * 0.78`.
    ///
    /// O quadro de altura zero deixa o rótulo transbordar simetricamente, então
    /// ele fica **centrado na linha** (o `align-items: center` do protótipo) em
    /// vez de pendurado abaixo dela. A linha continua no minuto exato da hora,
    /// que é o que mantém os cartões alinhados com a hora que dizem começar.
    private var hourLines: some View {
        ForEach(0...24, id: \.self) { hour in
            HStack(spacing: layout.gutterGap) {
                Text(Self.hourLabel(minuteOfDay: hour * 60))
                    .font(theme.mono.font(size: 9))
                    .foregroundStyle(theme.ink4.color)
                    .frame(width: layout.labelGutter, alignment: .trailing)
                Rectangle()
                    .fill(theme.line2.color)
                    .frame(height: Hairline.thickness(displayScale))
            }
            .frame(height: 0, alignment: .center)
            .offset(y: CGFloat(hour * 60) * layout.pointsPerMinute)
        }
    }

    /// O traço de "agora". Protótipo: `left: 26px; right: 0` — ele encosta na
    /// calha dos rótulos e não a atravessa.
    ///
    /// A trilha cobre o dia inteiro agora, então "agora" está sempre dentro
    /// da faixa (0...1440) — a checagem que existia aqui era o resquício da
    /// faixa 480-1140 e sumiu junto com ela.
    private var nowMarker: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: layout.nowMarkerLeading, height: 0)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(liveColor())
                    .frame(height: 1.5)
                nowDot
                    .frame(width: 4, height: 4)
            }
        }
        .frame(height: 0, alignment: .center)
        .offset(y: CGFloat(now) * layout.pointsPerMinute)
    }

    private var nowDot: some View {
        Circle()
            .fill(liveColor())
    }

    private func liveColor() -> Color {
        SemanticColor.live(isDark: theme.isDark)
    }

    private func eventBlock(_ item: AgendaItem) -> some View {
        Button { onOpenEvent(item) } label: {
            eventCard(item)
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusLarge)
        .help("Abre o compromisso")
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
        let tint = store.account(item.accountID)
            .flatMap { TokenColor(css: theme.isDark ? $0.tintDarkHex : $0.tintLightHex) } ?? theme.accent
        let account = store.account(item.accountID)

        return HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(tint.color)
                .frame(width: 3)

            Text(item.startLabel)
                .font(theme.mono.font(size: 10))
                .foregroundStyle(theme.ink2.color)
                .frame(width: 39, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(theme.sans.font(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(2)
                Text([account?.host, item.endLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(theme.sans.font(size: 10.5))
                    .foregroundStyle(theme.ink2.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .background(theme.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .contentShape(Rectangle())
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

extension AgendaItem {
    fileprivate var endLabel: String {
        String(format: "%02d:%02d", endMinute / 60, endMinute % 60)
    }
}

/// Mistura uma cor com transparência usando color-mix (simulado com SwiftUI).
private func soft(_ color: Color, _ opacity: CGFloat) -> Color {
    color.opacity(opacity)
}

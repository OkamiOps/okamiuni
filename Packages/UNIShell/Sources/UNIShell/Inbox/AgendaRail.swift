import SwiftUI
import UNIDesign
import UNICore

public struct AgendaRail: View {
    /// Apelido da largura canônica, que mora em `PaneLayout`.
    public static let width: CGFloat = PaneLayout.agendaWidth

    /// Converte minutos do dia em pontos na trilha.
    /// Faixa: 480 (08:00) a 1140 (19:00) = 660 minutos = 514.8 pontos
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
            660 * pointsPerMinute  // 1140 - 480 = 660 minutos
        }

        public func offset(for item: AgendaItem) -> CGFloat {
            CGFloat(item.startMinute - 480) * pointsPerMinute
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
    let store: MailStore
    let layout: Layout
    let now: Int  // minutos desde meia-noite, injetado para teste
    let headerDate: Date  // injetado para teste; default é hoje

    /// A largura resolvida que a janela concedeu.
    let railWidth: CGFloat

    /// Clicar num cartão abre a janela 04. Protótipo: cada evento da trilha tem
    /// `onOpen: () => this.openEvent(...)`.
    let onOpenEvent: (AgendaItem) -> Void

    public init(
        store: MailStore,
        layout: Layout = Layout(),
        now: Int? = nil,
        headerDate: Date? = nil,
        width: CGFloat = PaneLayout.agendaWidth,
        onOpenEvent: @escaping (AgendaItem) -> Void = { _ in }
    ) {
        self.store = store
        self.layout = layout
        self.now = now ?? Self.minutesNow()
        self.headerDate = headerDate ?? Date.now
        self.railWidth = width
        self.onOpenEvent = onOpenEvent
    }

    private static func minutesNow() -> Int {
        let d = Date()
        return d.hour * 60 + d.minute
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                ZStack(alignment: .topLeading) {
                    hourLines
                    nowMarker
                    ForEach(store.agenda) { item in
                        eventBlock(item)
                            .offset(y: layout.offset(for: item))
                    }
                }
                .frame(height: layout.totalHeight, alignment: .top)
                // Protótipo: `padding: 12px 14px 18px` na calha da trilha.
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 18)
            }
            pendingSection
        }
        .frame(width: railWidth)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {  // protótipo: margin-top: 3px
            Text(Self.headerDateString(headerDate))
                .font(theme.serif.font(size: 15, weight: .semibold))
                .foregroundStyle(theme.ink.color)
            HStack(spacing: 6) {
                Circle()
                    .fill(liveColor())
                    .frame(width: 5, height: 5)
                Text(Self.nextUpLabel(for: store.agenda, now: now))
                    .font(theme.mono.font(size: 10))
                    .foregroundStyle(theme.ink2.color)
                    .lineLimit(1)
            }
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
        ForEach(8..<19, id: \.self) { hour in
            HStack(spacing: layout.gutterGap) {
                Text(Self.hourLabel(minuteOfDay: hour * 60))
                    .font(theme.mono.font(size: 9))
                    .foregroundStyle(theme.ink4.color)
                    .frame(width: layout.labelGutter, alignment: .trailing)
                Rectangle()
                    .fill(theme.line2.color)
                    .frame(height: 0.5)
            }
            .frame(height: 0, alignment: .center)
            .offset(y: CGFloat(hour * 60 - 480) * layout.pointsPerMinute)
        }
    }

    /// O traço de "agora". Protótipo: `left: 26px; right: 0` — ele encosta na
    /// calha dos rótulos e não a atravessa.
    private var nowMarker: some View {
        Group {
            if now >= 480 && now <= 1140 {
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
                .offset(y: CGFloat(now - 480) * layout.pointsPerMinute)
            }
        }
    }

    private var nowDot: some View {
        Circle()
            .fill(liveColor())
    }

    private func liveColor() -> Color {
        let hex = theme.isDark ? "#FF7972" : "#D73337"
        return TokenColor(css: hex)?.color ?? theme.accent.color
    }

    private func eventBlock(_ item: AgendaItem) -> some View {
        Button { onOpenEvent(item) } label: {
            eventCard(item)
        }
        .buttonStyle(.plain)
        .help("Abre o compromisso")
    }

    private func eventCard(_ item: AgendaItem) -> some View {
        let tint = store.account(item.accountID)
            .flatMap { TokenColor(css: theme.isDark ? $0.tintDarkHex : $0.tintLightHex) } ?? theme.accent
        let tight = layout.isTight(for: item)
        let softColor = soft(tint.color, theme.isDark ? 0.18 : 0.10)

        return HStack(spacing: 0) {
            // Protótipo: `border-left: 2px solid c`.
            Rectangle()
                .fill(tint.color)
                .frame(width: 2)
            // Protótipo: `padding: 5px 8px` (ou `0 8px` quando apertado) e
            // `justify-content: center` — conteúdo centrado na altura do cartão.
            VStack(alignment: .leading, spacing: tight ? 0 : 2) {
                Text(tight ? "\(item.title) · \(item.startLabel)" : item.title)
                    .font(theme.sans.font(size: 11.5, weight: .semibold))
                    .foregroundStyle(tint.color)
                    .lineLimit(1)
                if !tight {
                    Text("\(item.startLabel)–\(item.endLabel)")
                        .font(theme.mono.font(size: 9))
                        .foregroundStyle(tint.color.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, tight ? 0 : 5)
            Spacer(minLength: 0)
        }
        .frame(height: layout.height(for: item), alignment: .leading)
        .background(softColor)
        // Protótipo: `border-radius: 0 var(--r2) var(--r2) 0` — quadrado do lado
        // da barra colorida, arredondado do lado de fora.
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: theme.radiusSmall,
                topTrailingRadius: theme.radiusSmall
            )
        )
        // Só o cartão clica; a calha da hora à esquerda continua livre.
        .contentShape(Rectangle())
        // Protótipo: `left: 32px; right: 2px`. O 32 é a calha de 26 mais a folga
        // de 6 — é o que impede o cartão de cobrir o rótulo da hora.
        .padding(.leading, layout.eventLeading)
        .padding(.trailing, layout.eventTrailing)
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Vindo do email")
                .font(theme.mono.font(size: 9.5))
                .tracking(theme.capsTracking(at: 9.5))
                .textCase(.uppercase)
                .foregroundStyle(theme.ink4.color)
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .padding(.bottom, 9)

            ForEach(Fixtures.pendingItems, id: \.id) { item in
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

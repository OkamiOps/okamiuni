import SwiftUI
import UNIDesign
import UNICore

public struct AgendaRail: View {
    public static let width: CGFloat = 262

    /// Converte minutos do dia em pontos na trilha.
    /// Faixa: 480 (08:00) a 1140 (19:00) = 660 minutos = 514.8 pontos
    public struct Layout: Sendable {
        public let pointsPerMinute: CGFloat

        public init(pointsPerMinute: CGFloat = 0.78) {
            self.pointsPerMinute = pointsPerMinute
        }

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

    public init(
        store: MailStore,
        layout: Layout = Layout(),
        now: Int? = nil,
        headerDate: Date? = nil
    ) {
        self.store = store
        self.layout = layout
        self.now = now ?? Self.minutesNow()
        self.headerDate = headerDate ?? Date.now
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
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            pendingSection
        }
        .frame(width: Self.width)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .hairline(theme.line2, edges: .bottom)
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(8..<19, id: \.self) { hour in
                HStack(alignment: .top, spacing: 6) {
                    Text(String(format: "%02d", hour))
                        .font(theme.mono.font(size: 9))
                        .foregroundStyle(theme.ink4.color)
                        .frame(width: 26, alignment: .trailing)
                    Rectangle()
                        .fill(theme.line2.color)
                        .frame(height: 0.5)
                    Spacer(minLength: 0)
                }
                .frame(height: 60 * layout.pointsPerMinute, alignment: .top)
            }
        }
    }

    private var nowMarker: some View {
        Group {
            if now >= 480 && now <= 1140 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        nowDot
                            .frame(width: 4, height: 4)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 0, alignment: .center)
                    .offset(x: 26)

                    Divider()
                        .frame(height: 1.5)
                        .background(liveColor())
                        .offset(y: -0.75)
                }
                .frame(height: 0, alignment: .top)
                .offset(y: layout.offset(for: AgendaItem(id: "", title: "", startMinute: now, endMinute: now + 1, accountID: "")))
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
        let tint = store.account(item.accountID)
            .flatMap { TokenColor(css: theme.isDark ? $0.tintDarkHex : $0.tintLightHex) } ?? theme.accent
        let tight = layout.isTight(for: item)
        let softColor = soft(tint.color, theme.isDark ? 0.18 : 0.10)

        return HStack(spacing: 0) {
            Rectangle()
                .fill(tint.color)
                .frame(width: 2.5)
            VStack(alignment: .leading, spacing: tight ? 0 : 2) {
                Text(tight ? "\(item.title) · \(item.startLabel)" : item.title)
                    .font(theme.sans.font(size: 11, weight: .medium))
                    .foregroundStyle(tint.color)
                    .lineLimit(1)
                if !tight {
                    Text("\(item.startLabel)–\(item.endLabel)")
                        .font(theme.mono.font(size: 9))
                        .foregroundStyle(theme.ink3.color.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            Spacer(minLength: 0)
        }
        .frame(height: layout.height(for: item), alignment: .top)
        .background(softColor)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.leading, 24)
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
                        .font(.system(size: 11.5, weight: .regular, design: .default))
                        .lineSpacing(0.45)  // 11.5 × 1.45 - 11.5 = 5.175 ≈ 0.45
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

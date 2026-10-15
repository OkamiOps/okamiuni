import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// As páginas da janela de Configurações, na ordem em que a navegação as
/// mostra.
///
/// Uma conta é uma **página**, e não uma linha dentro de uma lista de contas:
/// é a mudança de estrutura que o desenho pede. Tudo o que era de uma conta —
/// agenda, assinatura, remetentes, pastas — passou a morar na página dela.
enum ConfigPage: Hashable, Sendable {
    case overview
    case appearance
    case intelligence
    case account(String)
    case gestures
    case rules

    /// O item que fica aceso quando a página é um estado interno de outra.
    var navAnchor: ConfigPage { self }
}

/// A navegação de 244pt: os semáforos, o título, a busca, os quatro grupos e
/// o pé com a versão.
struct ConfigNav: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale

    let accounts: [AccountStatus]
    let pendingCount: Int
    let versionLine: String
    let readyUpdate: String?
    @Binding var page: ConfigPage
    @Binding var query: String
    let addAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            trafficLightReserve
            Text(L10n.tr("Configurações"))
                .font(theme.sans.font(size: 17, weight: .bold))
                .tracking(-0.01 * 17)
                .foregroundStyle(palette.ink.color)
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            search
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(L10n.tr("COMEÇO"), first: true)
                    item(.overview, L10n.tr("Visão geral"), symbol: "house", badge: pendingCount)
                    header(L10n.tr("VOCÊ"))
                    item(.appearance, L10n.tr("Aparência"), symbol: "paintpalette")
                    item(.intelligence, L10n.tr("Inteligência"), symbol: "sparkles")
                    header(L10n.tr("SUAS CONTAS"))
                    ForEach(visibleAccounts) { accountRow($0) }
                    addAccountRow
                    header(L10n.tr("AUTOMAÇÃO"))
                    item(.gestures, L10n.tr("Gestos"), symbol: "hand.draw")
                    item(.rules, L10n.tr("Regras"), symbol: "arrow.triangle.branch")
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(width: ConfigMetrics.navWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .configPanel(theme)
    }

    /// O vão dos semáforos **nativos**.
    ///
    /// O mock desenha três bolinhas porque lá não existe janela; aqui existe, e
    /// os botões do sistema são movidos para esta mesma linha por
    /// `trafficLightsInConfigNav()`. O que fica aqui é só a reserva de altura:
    /// `padding: 2px 6px 16px` em volta de bolinhas de 11.
    private var trafficLightReserve: some View {
        Color.clear
            .frame(height: 2 + 11 + 16)
            .accessibilityHidden(true)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.ink3.color)
            TextField(L10n.tr("Buscar um ajuste"), text: $query)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 13))
                .foregroundStyle(palette.ink.color)
            Text("⌘F")
                .font(theme.mono.font(size: 11))
                .foregroundStyle(palette.ink3.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(palette.field.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.line.color, lineWidth: Hairline.thickness(displayScale))
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 6)
        .accessibilityLabel(L10n.tr("Buscar um ajuste"))
    }

    private func header(_ text: String, first: Bool = false) -> some View {
        Text(text)
            .font(theme.sans.font(size: 11, weight: .semibold))
            .tracking(0.05 * 11)
            .foregroundStyle(palette.ink3.color)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func item(
        _ destination: ConfigPage, _ label: String, symbol: String, badge: Int = 0
    ) -> some View {
        let on = page.navAnchor == destination
        return Button { page = destination } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 17, height: 17)
                    .foregroundStyle((on ? palette.accentInk : palette.ink3).color)
                Text(label)
                    .font(theme.sans.font(size: 14, weight: on ? .semibold : .medium))
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(theme.sans.font(size: 11, weight: .bold))
                        .foregroundStyle(palette.onAccent.color)
                        .padding(.horizontal, 2)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(palette.accent.color, in: Capsule())
                }
            }
            .foregroundStyle((on ? palette.ink : palette.ink2).color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selectionBackground(on))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 10)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func accountRow(_ status: AccountStatus) -> some View {
        let on = page.navAnchor == .account(status.accountID)
        return Button { page = .account(status.accountID) } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(ConfigAccountTint.color(for: status, theme: theme))
                    .frame(width: 9, height: 9)
                Text(status.address)
                    .font(theme.sans.font(size: 13.5, weight: on ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Circle()
                    .fill(ConfigAccountTint.health(for: status, palette: palette).color)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(AccountsCopy.isFailing(status)
                        ? L10n.tr("Pedindo atenção")
                        : L10n.tr("Sincronizada"))
            }
            .foregroundStyle((on ? palette.ink : palette.ink2).color)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .background(selectionBackground(on))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 10)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private var addAccountRow: some View {
        Button(action: addAccount) {
            HStack(spacing: 10) {
                Text("+")
                    .frame(width: 9)
                Text(L10n.tr("Adicionar conta"))
                Spacer(minLength: 0)
            }
            .font(theme.sans.font(size: 13, weight: .medium))
            .foregroundStyle(palette.ink3.color)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 8)
    }

    @ViewBuilder
    private func selectionBackground(_ on: Bool) -> some View {
        if on {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.navOn.color)
                .modifier(ConditionalShadow(layers: palette.segShadow))
        } else {
            Color.clear
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("O")
                .font(theme.sans.font(size: 13, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(
                    LinearGradient(
                        colors: [
                            Color(.sRGB, red: 109 / 255, green: 99 / 255, blue: 255 / 255),
                            Color(.sRGB, red: 192 / 255, green: 132 / 255, blue: 252 / 255),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(versionLine)
                    .font(theme.sans.font(size: 12, weight: .semibold))
                    .foregroundStyle(palette.ink.color)
                    .lineLimit(1)
                if let readyUpdate {
                    Text(L10n.tr("\(readyUpdate) pronta para instalar"))
                        .font(theme.sans.font(size: 12, weight: .medium))
                        .foregroundStyle(palette.accentInk.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.horizontal, -2)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.line.color)
                .frame(height: Hairline.thickness(displayScale))
                .padding(.horizontal, -2)
        }
        .padding(.top, 10)
    }

    /// A busca filtra as contas pelo endereço. Os ajustes fixos continuam
    /// visíveis: esconder "Aparência" porque a pessoa digitou "gmail" seria
    /// trocar uma lista curta por um labirinto.
    private var visibleAccounts: [AccountStatus] {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return accounts }
        return accounts.filter { $0.address.localizedCaseInsensitiveContains(term) }
    }
}

/// A cor da conta e a bolinha de saúde dela, num lugar só: a navegação, a
/// visão geral e a página da conta precisam dizer a mesma coisa.
enum ConfigAccountTint {
    static func color(for status: AccountStatus, theme: Theme) -> Color {
        // A conta tem tinta própria no banco; a lateral da caixa já a usa.
        // Sem ela, a marca do host dá uma cor estável — o mesmo endereço
        // recebe sempre o mesmo ponto.
        let paleta: [TokenColor] = [
            TokenColor(red: 109 / 255, green: 99 / 255, blue: 255 / 255),
            TokenColor(red: 14 / 255, green: 165 / 255, blue: 233 / 255),
            TokenColor(red: 245 / 255, green: 158 / 255, blue: 11 / 255),
            TokenColor(red: 16 / 255, green: 185 / 255, blue: 129 / 255),
            TokenColor(red: 236 / 255, green: 72 / 255, blue: 153 / 255),
        ]
        let indice = abs(status.accountID.hashValue) % paleta.count
        return paleta[indice].color
    }

    static func health(for status: AccountStatus, palette: ConfigPalette) -> TokenColor {
        if AccountsCopy.isFailing(status) { return palette.orange }
        if status.state == .carregando { return palette.accent }
        return palette.green
    }

    static func initial(for status: AccountStatus) -> String {
        String(status.address.prefix(1)).uppercased()
    }
}

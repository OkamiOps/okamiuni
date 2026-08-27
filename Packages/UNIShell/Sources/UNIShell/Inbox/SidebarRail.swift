import SwiftUI
import UNIDesign
import UNICore

public struct SidebarRail: View {
    public static let width: CGFloat = 62

    @Environment(\.theme) private var theme
    let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    /// Abreviação de três a quatro letras que a trilha usa no lugar do rótulo
    /// completo. Vem do protótipo: `short: ['hoje', 'dep', 'tudo', 'arq']`.
    public static func abbreviation(for bucket: TriageBucket) -> String {
        switch bucket {
        case .today: "hoje"
        case .later: "dep"
        case .all: "tudo"
        case .archived: "arq"
        }
    }

    public var body: some View {
        VStack(alignment: .center, spacing: 4) {
            // Pastas (Fluxo) — fixas no topo
            VStack(alignment: .center, spacing: 4) {
                ForEach(TriageBucket.allCases, id: \.self) { bucket in
                    bucketButton(bucket)
                }
            }

            // Contas com scroll (divisória, rótulo e marcas)
            if !store.accounts.isEmpty {
                ScrollView {
                    VStack(alignment: .center, spacing: 4) {
                        // Divisória
                        Rectangle()
                            .fill(theme.line.color)
                            .frame(width: 26, height: 0.5)
                            .padding(.vertical, 8)

                        // Rótulo "caixas" com tracking fixo do protótipo, não do tema
                        Text("caixas")
                            .font(theme.mono.font(size: 7.5))
                            .tracking(0.08 * 7.5)  // Tracking em pontos: 0.08em × 7.5pt = 0.6pt
                            .textCase(.uppercase)
                            .foregroundStyle(theme.ink4.color)
                            .padding(.bottom, 2)

                        // Contas
                        ForEach(store.accounts) { account in
                            accountMark(account)
                        }
                    }
                }
            }
        }
        .frame(width: Self.width, alignment: .center)
        .padding(.vertical, 14)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .trailing)
    }

    private func bucketButton(_ bucket: TriageBucket) -> some View {
        let active = bucket == store.bucket
        let abbr = Self.abbreviation(for: bucket)

        return Button { store.select(bucket: bucket) } label: {
            VStack(alignment: .center, spacing: 3) {
                Text(abbr)
                    .font(theme.mono.font(size: 8.5))
                    .tracking(0.06 * 8.5)  // Tracking em pontos: 0.06em × 8.5pt = 0.51pt
                    .textCase(.uppercase)

                Text("\(store.count(for: bucket))")
                    .font(theme.mono.font(size: 13, weight: .semibold))
                    // Peso 650 não existe em Font.Weight (enum: 100,300,400,500,600,700,800,900).
                    // Semibold (600) é o vizinho mais próximo, como em Task 7.
                    // Para peso exato, seria preciso Core Text e fonte variável.
            }
            .foregroundStyle((active ? theme.accentInk : theme.ink3).color)
            .frame(width: 46, height: 40)
            .background {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .fill(active ? theme.accentSoft.color : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .stroke(
                        active ? theme.accentLine.color : Color.clear,
                        lineWidth: 0.5
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private func accountMark(_ account: Account) -> some View {
        let active = account.id == store.selectedAccountID
        let tintColor = account.tint(isDark: theme.isDark)
        let tintTokenColor = TokenColor(css: tintColor) ?? theme.ink4
        let mark = account.host.prefix(3).uppercased()

        return Button { store.select(account: account.id) } label: {
            Text(mark)
                .font(theme.mono.font(size: 10, weight: .medium))
                .foregroundStyle(tintTokenColor.color)
                .frame(width: 40, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .fill(opacityMix(tintColor, active ? 26 : 12))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .stroke(
                            opacityMix(tintColor, active ? 70 : 26),
                            lineWidth: 0.5
                        )
                }
                .help(account.address)
        }
        .buttonStyle(.plain)
    }

    private func opacityMix(_ hexColor: String, _ percentage: Int) -> Color {
        // Simulates: color-mix(in oklab, hexColor percentage%, transparent)
        guard let tokenColor = TokenColor(css: hexColor) else {
            return Color.clear
        }
        return tokenColor.color.opacity(Double(percentage) / 100.0)
    }
}

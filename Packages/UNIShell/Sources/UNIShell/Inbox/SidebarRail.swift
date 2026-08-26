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

    public var body: some View {
        VStack(alignment: .center, spacing: 4) {
            ScrollView {
                VStack(alignment: .center, spacing: 4) {
                    // Pastas (Fluxo)
                    ForEach(TriageBucket.allCases, id: \.self) { bucket in
                        bucketButton(bucket)
                    }

                    // Divisória
                    Rectangle()
                        .fill(theme.line.color)
                        .frame(width: 26, height: 0.5)
                        .padding(.vertical, 8)

                    // Rótulo "caixas"
                    Text("caixas")
                        .capsLabel(size: 7.5)
                        .padding(.bottom, 2)

                    // Contas
                    ForEach(store.accounts) { account in
                        accountMark(account)
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
        let abbreviations = ["hoje", "dep", "tudo", "arq"]
        let index = TriageBucket.allCases.firstIndex(of: bucket) ?? 0
        let abbr = index < abbreviations.count ? abbreviations[index] : ""

        return Button { store.select(bucket: bucket) } label: {
            VStack(alignment: .center, spacing: 3) {
                Text(abbr)
                    .font(theme.mono.font(size: 8.5))
                    .tracking(0.06)  // 0.06em in CSS
                    .textCase(.uppercase)

                Text("\(store.count(for: bucket))")
                    .font(theme.mono.font(size: 13, weight: .semibold))  // 650 ≈ semibold
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

import SwiftUI
import UNIDesign
import UNICore

public struct FolderSidebar: View {
    public static let expandedWidth: CGFloat = 236

    @Environment(\.theme) private var theme
    let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Seção "Fluxo"
                    sectionHeader("Fluxo", padding: EdgeInsets(top: 0, leading: 16, bottom: 7, trailing: 16))
                    ForEach(TriageBucket.allCases, id: \.self) { bucket in
                        bucketRow(bucket)
                    }

                    // Seção "Caixas"
                    if !store.accounts.isEmpty {
                        sectionHeader("Caixas", padding: EdgeInsets(top: 22, leading: 16, bottom: 7, trailing: 16))
                        ForEach(store.accounts) { account in
                            accountRow(account)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Rodapé fixo
            Divider()
                .frame(height: 0.5)
                .background(theme.line.color)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(TokenColor(css: oklchToHex(L: 0.80, C: 0.11, H: 150))?.color ?? theme.ink2.color)
                        .frame(width: 5, height: 5)
                    Text("Triagem local ativa")
                        .font(theme.mono.font(size: 11.5, weight: .semibold))
                        .foregroundStyle(theme.ink2.color)
                }
                Text("Classificação, resumo e busca semântica rodam no Mac. Nada sai daqui.")
                    .font(theme.mono.font(size: 11))
                    .lineSpacing(1.5 - 1.0)
                    .foregroundStyle(theme.ink3.color)
            }
            .padding(16)
        }
        .frame(width: Self.expandedWidth, alignment: .leading)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .trailing)
    }

    private func sectionHeader(_ title: String, padding: EdgeInsets) -> some View {
        Text(title)
            .capsLabel(size: 9.5)
            .padding(padding)
    }

    private func bucketRow(_ bucket: TriageBucket) -> some View {
        let active = bucket == store.bucket
        return Button { store.select(bucket: bucket) } label: {
            HStack(spacing: 9) {
                Text(bucket.label)
                    .font(theme.sans.font(size: 13, weight: .medium))
                    .foregroundStyle((active ? theme.accentInk : theme.ink2).color)
                Spacer(minLength: 0)
                Text("\(store.count(for: bucket))")
                    .font(theme.mono.font(size: 10))
                    .foregroundStyle((active ? theme.accentInk : theme.ink4).color)
            }
            .frame(height: 30)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background {
                if active {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .fill(theme.accentSoft.color)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func accountRow(_ account: Account) -> some View {
        let active = account.id == store.selectedAccountID
        let tintColor = account.tint(isDark: theme.isDark)
        let tintTokenColor = TokenColor(css: tintColor) ?? theme.ink4

        return Button { store.select(account: account.id) } label: {
            HStack(spacing: 8) {
                // Chip do host
                Text(account.host.uppercased())
                    .font(theme.mono.font(size: 9, weight: .medium))
                    .tracking(theme.capsTracking(at: 9))
                    .foregroundStyle(tintTokenColor.color)
                    .frame(height: 14)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(opacityMix(tintColor, active ? 22 : 14))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(opacityMix(tintColor, 32), lineWidth: 0.5)
                    }

                // Endereço
                Text(account.address)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink2.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(account.address)

                // Contador (mensagens da conta)
                Text("\(store.messages.filter { $0.accountID == account.id }.count)")
                    .font(theme.mono.font(size: 10))
                    .foregroundStyle(theme.ink4.color)
            }
            .frame(height: 32)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background {
                if active {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .fill(opacityMix(tintColor, 16))
                }
            }
            .overlay(alignment: .leading) {
                if active {
                    Rectangle()
                        .fill(tintTokenColor.color)
                        .frame(width: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func opacityMix(_ hexColor: String, _ percentage: Int) -> Color {
        // Simulates: color-mix(in oklab, hexColor percentage%, transparent)
        // In SwiftUI, we use opacity as approximation
        guard let tokenColor = TokenColor(css: hexColor) else {
            return Color.clear
        }
        return tokenColor.color.opacity(Double(percentage) / 100.0)
    }

    private func oklchToHex(L: Double, C: Double, H: Double) -> String {
        // For now, return the hardcoded OK (green) color from the prototype
        // This represents oklch(0.80 0.11 150) which is the "ok" semantic color in dark theme
        "#9DDB7E"
    }
}

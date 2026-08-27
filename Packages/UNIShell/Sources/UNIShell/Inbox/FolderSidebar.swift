import SwiftUI
import UNIDesign
import UNICore

public struct FolderSidebar: View {
    /// A largura canônica mora em `PaneLayout`, que é quem decide o que cabe.
    /// Este nome continua existindo porque o resto do shell já o usa — mas ele
    /// agora é um apelido, não uma segunda fonte da verdade.
    public static let expandedWidth: CGFloat = PaneLayout.expandedSidebarWidth

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let store: MailStore

    /// A largura resolvida que a janela concedeu. O padrão é a canônica, para
    /// que previews e testes não precisem calcular layout.
    let width: CGFloat

    public init(store: MailStore, width: CGFloat = PaneLayout.expandedSidebarWidth) {
        self.store = store
        self.width = width
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Seção "Fluxo"
                    sectionHeader("Fluxo", padding: EdgeInsets(top: 0, leading: 16, bottom: 7, trailing: 16))
                    // Protótipo: a lista tem `padding: 0 8px; gap: 1px`, e cada
                    // linha tem os seus próprios `padding: 0 8px`. É essa soma
                    // que põe o rótulo da pasta na mesma coluna do "FLUXO", em
                    // 16pt — sem ela a linha nasce em 8 e o realce sangra até a
                    // borda da barra.
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(TriageBucket.allCases, id: \.self) { bucket in
                            bucketRow(bucket)
                        }
                    }
                    .padding(.horizontal, 8)

                    // Seção "Caixas"
                    if !store.accounts.isEmpty {
                        sectionHeader("Caixas", padding: EdgeInsets(top: 22, leading: 16, bottom: 7, trailing: 16))
                        VStack(alignment: .leading, spacing: 2) {  // protótipo: gap: 2px
                            ForEach(store.accounts) { account in
                                accountRow(account)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)  // padding-top: 14 do container
            }

            // Rodapé fixo
            // `Divider()` não é a divisória deste design: ele pinta a cor do
            // separador do sistema (medido, `rgb(202,199,192)`) por baixo do
            // fundo pedido, e sai 22 níveis mais escuro que `--line`. Era o
            // único traço da tela fora do idioma da hairline.
            Rectangle()
                .fill(theme.line.color)
                .frame(height: Hairline.thickness(displayScale))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(triageDotColor(isDark: theme.isDark).color)
                        .frame(width: 5, height: 5)
                    Text("Triagem local ativa")
                        .font(theme.sans.font(size: 11.5, weight: .semibold))
                        // Peso 590 do protótipo arredondado para .semibold (600) — sem peso intermediário em SwiftUI
                        .foregroundStyle(theme.ink2.color)
                }
                Text("Classificação, resumo e busca semântica rodam no Mac. Nada sai daqui.")
                    .font(theme.sans.font(size: 11))
                    .lineSpacing(5.5)  // line-height: 1.5 × 11pt − 11pt = 16.5 − 11 = 5.5
                    .foregroundStyle(theme.ink3.color)
            }
            .padding(16)
        }
        .frame(width: width, alignment: .leading)
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
        .focusRing(cornerRadius: theme.radiusSmall)
        // O menu da caixa tem um item só, e ele some quando não há o que
        // marcar — caixa toda lida não abre menu nenhum, em vez de abrir um
        // com a linha desabilitada dizendo o contrário do contador ao lado.
        .uniContextMenu(
            ContextMenus.bucketRow(
                bucket,
                unread: store.unreadCount(in: bucket, accountID: store.selectedAccountID),
                accountID: store.selectedAccountID
            ),
            store: store
        )
    }

    private func accountRow(_ account: Account) -> some View {
        let active = account.id == store.selectedAccountID
        let tintColor = account.tint(isDark: theme.isDark)
        let tintTokenColor = TokenColor(css: tintColor) ?? theme.ink4

        return Button { store.select(account: account.id) } label: {
            HStack(spacing: 8) {
                // Chip do host — o mesmo `chip()` do protótipo que a lista usa.
                TintChip(label: account.host, tint: tintTokenColor.color, emphasized: active)

                // Endereço
                Text(account.address)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink2.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(account.address)

                // Sem isto a linha mede o conteúdo, e como cada endereço tem um
                // comprimento diferente **cada seleção pintava uma largura
                // diferente** — e o contador ficava colado no endereço em vez de
                // alinhado à direita. A linha de pasta sempre teve este `Spacer`.
                Spacer(minLength: 0)

                // Contador (mensagens da conta)
                Text("\(store.messages.filter { $0.accountID == account.id }.count)")
                    .font(theme.mono.font(size: 10))
                    .foregroundStyle(theme.ink4.color)
            }
            .frame(maxWidth: .infinity)
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
        .focusRing(cornerRadius: theme.radiusSmall)
        .uniContextMenu(
            ContextMenus.accountRow(
                account,
                isFiltered: active,
                // A conta inteira, não a caixa aberta: a linha da conta não
                // pertence a caixa nenhuma.
                unread: store.unreadCount(in: .all, accountID: account.id)
            ),
            store: store
        )
    }

    private func opacityMix(_ hexColor: String, _ percentage: Int) -> Color {
        // Simulates: color-mix(in oklab, hexColor percentage%, transparent)
        // In SwiftUI, we use opacity as approximation
        guard let tokenColor = TokenColor(css: hexColor) else {
            return Color.clear
        }
        return tokenColor.color.opacity(Double(percentage) / 100.0)
    }

    private func triageDotColor(isDark: Bool) -> TokenColor {
        // Cor semântica "ok" do protótipo (semC('ok') no JavaScript do protótipo).
        // Adapta conforme o tema para manter contraste e legibilidade.
        let hexColor = isDark
            ? "#89D298"  // tema escuro: oklch(0.80 0.11 150)
            : "#317A45"  // tema claro: oklch(0.52 0.11 150)
        return TokenColor(css: hexColor) ?? theme.ink2
    }
}


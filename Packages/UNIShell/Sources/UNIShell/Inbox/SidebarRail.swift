import SwiftUI
import UNIDesign
import UNICore

public struct SidebarRail: View {
    /// Apelido da largura canônica, que mora em `PaneLayout`.
    public static let width: CGFloat = PaneLayout.railWidth

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    let store: MailStore

    /// A largura resolvida que a janela concedeu.
    let railWidth: CGFloat

    /// A trilha precisa carregar a mesma porta de entrada da barra aberta: a
    /// janela pode recolher, mas a pergunta não pode desaparecer junto.
    let intelligencePresentation: IntelligencePresentation
    let onOpenAssistant: () -> Void

    /// Ver `FolderSidebar.confirmingEmptyTrash`: a trilha é a mesma barra
    /// lateral, recolhida, e a ação destrutiva não pode perder a pergunta só
    /// porque a janela apertou.
    @State private var confirmingEmptyTrash = false

    public init(
        store: MailStore,
        width: CGFloat = PaneLayout.railWidth,
        intelligencePresentation: IntelligencePresentation = .available,
        onOpenAssistant: @escaping () -> Void = {}
    ) {
        self.store = store
        self.railWidth = width
        self.intelligencePresentation = intelligencePresentation
        self.onOpenAssistant = onOpenAssistant
    }

    /// Abreviação de três a quatro letras que a trilha usa no lugar do rótulo
    /// completo. Vem do protótipo: `short: ['hoje', 'dep', 'tudo', 'arq']`.
    /// A Lixeira, que o protótipo não tinha, segue a regra: "lixo".
    public static func abbreviation(for bucket: TriageBucket) -> String {
        switch bucket {
        case .today: "hoje"
        case .later: "dep"
        case .all: "tudo"
        case .archived: "arq"
        case .trash: "lixo"
        case .sent: "env"
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
                            .frame(width: 26, height: Hairline.thickness(displayScale))
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
                .frame(maxHeight: .infinity)
            }

            Spacer(minLength: 8)
            assistantButton
        }
        .frame(width: railWidth, alignment: .center)
        .padding(.vertical, 14)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .trailing)
    }

    private var assistantButton: some View {
        Button(action: onOpenAssistant) {
            VStack(spacing: 4) {
                Image(systemName: intelligencePresentation.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                // A trilha tem só 62pt: "perguntar" virava uma palavra
                // cortada. A abreviação conserva o verbo e deixa o ícone ser a
                // âncora visual, enquanto `help` e acessibilidade dizem a ação
                // inteira.
                Text("perg.")
                    .font(theme.mono.font(size: 7.5, weight: .medium))
                    .tracking(theme.capsTracking(at: 7.5))
                    .textCase(.uppercase)
                    .lineLimit(1)
            }
            .foregroundStyle((intelligencePresentation.isAvailable ? theme.accentInk : theme.ink4).color)
            .frame(width: 46, height: 50)
            .background(intelligencePresentation.isAvailable ? theme.accentSoft.color : theme.surface3.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(
                        (intelligencePresentation.isAvailable ? theme.accentLine : theme.line2).color,
                        lineWidth: Hairline.thickness(displayScale)
                    )
            }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .disabled(!intelligencePresentation.isAvailable)
        .help(intelligencePresentation.actionHelp)
        .accessibilityLabel(intelligencePresentation.actionTitle)
        .accessibilityValue(intelligencePresentation.isAvailable ? "Disponível" : "Indisponível")
        .accessibilityHint(intelligencePresentation.actionHelp)
    }

    private func bucketButton(_ bucket: TriageBucket) -> some View {
        let active = bucket == store.bucket
        let abbr = Self.abbreviation(for: bucket)

        return Button { store.select(bucket: bucket) } label: {
            VStack(alignment: .center, spacing: 3) {
                // A abreviação da Lixeira vem com o símbolo à frente, como na
                // barra larga: 62pt de trilha e quatro letras não distinguem
                // "arq" de "lixo" no canto do olho.
                if let symbol = FolderSidebar.symbol(for: bucket) {
                    Image(systemName: symbol)
                        .font(.system(size: 9))
                        .accessibilityHidden(true)
                }
                Text(abbr)
                    .font(theme.mono.font(size: 8.5))
                    .tracking(0.06 * 8.5)  // Tracking em pontos: 0.06em × 8.5pt = 0.51pt
                    .textCase(.uppercase)

                // O mesmo número da barra larga — total em Enviadas, não lidas
                // no resto. Ver `FolderSidebar.counter(for:store:)`: a trilha é
                // a mesma barra recolhida, e dois números diferentes para a
                // mesma caixa seriam dois aplicativos.
                Text("\(FolderSidebar.counter(for: bucket, store: store))")
                    // O protótipo não declara família nesta contagem, então ela
                    // herda a sans do corpo — não é mono como a abreviação acima.
                    .font(theme.sans.font(size: 13, weight: .semibold))
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
                // `strokeBorder`, não `stroke`: o traçado do `stroke` fica
                // **em cima** da borda, metade para dentro e metade para fora,
                // e em 1× essa metade cai entre dois pixels — a borda do botão
                // ativo saía espalhada em `rgb(224,227,231)` + `rgb(219,226,235)`,
                // nenhum dos dois o `accentLine` do token. `strokeBorder`
                // desenha para dentro da forma e entrega o token exato. Era o
                // último resquício das "bordas falhadas" do relato.
                RoundedRectangle(cornerRadius: theme.radiusSmall)
                    .strokeBorder(
                        active ? theme.accentLine.color : Color.clear,
                        lineWidth: Hairline.thickness(displayScale)
                    )
            }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        // A trilha é a mesma barra lateral, recolhida — e o menu tem de ser o
        // mesmo. Um menu que só existisse na versão larga faria a ação sumir
        // exatamente quando a janela aperta e o rótulo já não cabe.
        .uniContextMenu(
            ContextMenus.bucketRow(
                bucket,
                unread: store.unreadCount(in: bucket, accountID: store.selectedAccountID),
                accountID: store.selectedAccountID,
                trash: store.trashCount(accountID: store.selectedAccountID)
            ),
            store: store,
            intercept: { command in
                guard case .emptyTrash = command else { return false }
                confirmingEmptyTrash = true
                return true
            }
        )
        .modifier(EmptyTrashConfirmation(store: store, isPresented: $confirmingEmptyTrash))
    }

    private func accountMark(_ account: Account) -> some View {
        let active = account.id == store.selectedAccountID
        let tintColor = account.tint(isDark: theme.isDark)
        let tintTokenColor = TokenColor(css: tintColor) ?? theme.ink4
        let mark = HostMark.rail(account.host)

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
                    // Ver a borda do botão de pasta acima: `strokeBorder`
                    // desenha para dentro da forma, `stroke` monta em cima dela.
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .strokeBorder(
                            opacityMix(tintColor, active ? 70 : 26),
                            lineWidth: Hairline.thickness(displayScale)
                        )
                }
                .help(account.address)
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .uniContextMenu(
            ContextMenus.accountRow(
                account,
                isFiltered: active,
                unread: store.unreadCount(in: .all, accountID: account.id)
            ),
            store: store
        )
    }

    private func opacityMix(_ hexColor: String, _ percentage: Int) -> Color {
        // Simulates: color-mix(in oklab, hexColor percentage%, transparent)
        guard let tokenColor = TokenColor(css: hexColor) else {
            return Color.clear
        }
        return tokenColor.color.opacity(Double(percentage) / 100.0)
    }
}

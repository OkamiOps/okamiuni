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

    /// Qual caixa está esperando a confirmação de "Esvaziar lixeira".
    ///
    /// É o **único** destrutivo sem volta do app, e o único que pergunta antes.
    /// Arquivar, apagar e apagar definitivamente têm "Desfazer"; este não tem,
    /// e a pergunta é o que fica no lugar dele.
    @State private var confirmingEmptyTrash = false

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
                                // As pastas do provedor, quando a conta está
                                // aberta. Elas ficam **dentro** da seção
                                // CAIXAS, logo abaixo da conta a que pertencem:
                                // uma seção própria as separaria da conta e a
                                // barra teria de repetir o endereço em cada
                                // grupo.
                                if store.foldersExpanded(account.id) {
                                    ForEach(store.folders(of: account.id)) { folder in
                                        folderRow(folder, account: account)
                                    }
                                }
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
                // A Lixeira é a única caixa com símbolo, e ele não é enfeite:
                // ela é a única cujo conteúdo se perde, e o ícone é o que a
                // distingue à primeira vista de "Arquivado", logo acima. As
                // outras quatro continuam só com o nome, como no protótipo.
                if let symbol = Self.symbol(for: bucket) {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle((active ? theme.accentInk : theme.ink3).color)
                        .accessibilityHidden(true)
                }
                Text(bucket.label)
                    .font(theme.sans.font(size: 13, weight: .medium))
                    .foregroundStyle((active ? theme.accentInk : theme.ink2).color)
                Spacer(minLength: 0)
                Text("\(Self.counter(for: bucket, store: store))")
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
        // Os itens da caixa somem quando não há o que fazer: caixa toda lida
        // não oferece "Marcar tudo como lido", Lixeira vazia não oferece
        // "Esvaziar lixeira". Aqui sumir é certo — ao contrário do menu da
        // mensagem, onde a lista de ações de topo tem de ser estável, o menu da
        // caixa existe só pelo que ela tem agora; uma linha apagada diria o
        // contrário do contador ao lado dela.
        .uniContextMenu(
            ContextMenus.bucketRow(
                bucket,
                unread: store.unreadCount(in: bucket, accountID: store.selectedAccountID),
                accountID: store.selectedAccountID,
                trash: store.trashCount(accountID: store.selectedAccountID)
            ),
            store: store,
            // "Esvaziar lixeira" não vai direto ao store: ele para aqui e
            // pergunta. É a troca que o item faz por não ter "Desfazer".
            intercept: { command in
                guard case .emptyTrash = command else { return false }
                confirmingEmptyTrash = true
                return true
            }
        )
        .modifier(EmptyTrashConfirmation(store: store, isPresented: $confirmingEmptyTrash))
    }

    /// O símbolo de uma caixa, quando ela tem um.
    ///
    /// Duas têm, e pela mesma razão: elas são as que **não** são triagem. A
    /// Lixeira é a única cujo conteúdo se perde; Enviadas é a única que guarda
    /// o que saiu. O ícone é o que as distingue à primeira vista de
    /// "Arquivado", entre as quais elas estão. As outras quatro continuam só
    /// com o nome, como no protótipo.
    static func symbol(for bucket: TriageBucket) -> String? {
        switch bucket {
        case .trash: "trash"
        case .sent: "paperplane"
        default: nil
        }
    }

    /// O número que a caixa mostra à direita.
    ///
    /// Não lidas em toda caixa da triagem — é o que o dono pediu, e o que o
    /// webmail mostra. **Menos em Enviadas**, que mostra o total: uma mensagem
    /// que você escreveu nasce lida, então "não lidas" ali seria zero para
    /// sempre — um contador que nunca se move é ruído com cara de informação.
    static func counter(for bucket: TriageBucket, store: MailStore) -> Int {
        bucket == .sent
            ? store.count(for: bucket)
            : store.unreadCount(in: bucket, accountID: store.selectedAccountID)
    }

    /// A linha de uma pasta do provedor, dentro da conta aberta.
    ///
    /// Ela recua 14pt em relação à linha da conta — o mesmo recuo que a seta
    /// ocupa lá em cima — e é isso que diz "esta pasta é daquela conta" sem
    /// precisar de moldura, linha guia nem repetir o endereço.
    private func folderRow(_ folder: MailFolder, account: Account) -> some View {
        let active = folder.id == store.selectedFolderID
        let tintColor = account.tint(isDark: theme.isDark)
        let tintTokenColor = TokenColor(css: tintColor) ?? theme.ink4

        return Button { store.select(folder: folder.id) } label: {
            HStack(spacing: 7) {
                // O ícone só existe para a pasta de papel conhecido — lixeira,
                // enviadas, rascunhos, spam. A que a pessoa criou não tem
                // nenhum, e um ícone genérico ao lado de todas roubaria o sinal
                // das que têm um. Ver `MailFolder.symbol`.
                Group {
                    if let symbol = folder.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 10))
                            .foregroundStyle((active ? theme.accentInk : theme.ink4).color)
                    }
                }
                .frame(width: 12)
                .accessibilityHidden(true)

                Text(folder.displayName)
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle((active ? theme.accentInk : theme.ink2).color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // O caminho inteiro no `help`: a linha corta pelo meio uma
                    // subpasta longa ("Clientes/2026/Faturas"), e o balão é
                    // onde ele cabe sem alargar a barra.
                    .help(folder.serverName)

                Spacer(minLength: 0)

                // Zero não é desenhado: uma coluna de zeros ao lado de doze
                // pastas é ruído com cara de informação, e o que importa numa
                // pasta é justamente ela ter alguma coisa por ler.
                if folder.unreadCount > 0 {
                    Text("\(folder.unreadCount)")
                        .font(theme.mono.font(size: 10))
                        .foregroundStyle((active ? theme.accentInk : theme.ink4).color)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .padding(.leading, 22)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
            .background {
                if active {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .fill(opacityMix(tintColor, 16))
                }
            }
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
    }

    private func accountRow(_ account: Account) -> some View {
        let active = account.id == store.selectedAccountID
        let tintColor = account.tint(isDark: theme.isDark)
        let tintTokenColor = TokenColor(css: tintColor) ?? theme.ink4
        // **A seta só existe quando há pasta.** Sem conta conectada — as
        // fixtures — não há pasta de provedor nenhuma, e a linha da conta fica
        // exatamente como o Marco 1 a desenhava, até o pixel. É a mesma regra
        // que o app inteiro segue: sem conta, nada muda.
        let pastas = store.folders(of: account.id)

        return Button { store.select(account: account.id) } label: {
            HStack(spacing: 8) {
                if !pastas.isEmpty {
                    // A seta é o idioma de recolhível desta base — o mesmo "▾"
                    // aberto / "▸" fechado do cabeçalho de seção da janela de
                    // compromisso (M3-13), e não um `DisclosureGroup`, que traz
                    // desenho e espaçamento próprios do sistema.
                    //
                    // Ela **não** é um botão dentro de um botão: é um alvo de
                    // toque desenhado dentro do rótulo, com o gesto próprio por
                    // cima. Um `Button` aninhado teria dois estilos, dois anéis
                    // de foco e um clique que às vezes chega ao de fora.
                    Text(store.foldersExpanded(account.id) ? "▾" : "▸")
                        .font(theme.mono.font(size: 9))
                        .foregroundStyle(theme.ink4.color)
                        .frame(width: 10, height: 24)
                        .contentShape(Rectangle())
                        .onTapGesture { store.toggleFolders(of: account.id) }
                        .accessibilityLabel(
                            store.foldersExpanded(account.id)
                                ? "Recolher as pastas de \(account.address)"
                                : "Mostrar as pastas de \(account.address)"
                        )
                }

                // Chip do host — o mesmo `chip()` do protótipo que a lista usa.
                TintChip(label: account.host, tint: tintTokenColor.color, emphasized: active)

                // Endereço
                Text(account.address)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink2.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(account.address)

                // O estado da conta na lateral, sem tirar espaço do endereço:
                // um ponto, com o `help` dizendo o que ele significa. Conta
                // parada sem sinal nenhum foi o defeito que a janela de Contas
                // existe para não repetir.
                if account.state != .ativa {
                    Circle()
                        .fill(account.state == .carregando ? theme.ink4.color : theme.accent.color)
                        .frame(width: 6, height: 6)
                        .help(account.state == .carregando
                            ? "Carregando as mensagens desta conta…"
                            : "Esta conta precisa ser reconectada. Abra Configurações…")
                }

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


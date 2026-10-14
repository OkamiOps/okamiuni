import SwiftUI
import UNICore
import UNIDesign

/// Um bloco do painel "Mover para pasta" — o título da seção e as pastas.
struct MoveFolderGroup: Identifiable, Hashable {
    var id: String { title }
    let title: String
    let items: [ContextMenuItem]
}

/// O balão "Mover para…", nosso, no lugar do `Menu` do sistema.
///
/// A lista do Gmail tem dezenas de marcadores e o submenu nativo ocupava a
/// tela inteira. Aqui cabem **20 linhas** e o resto rola.
///
/// ## O desenho
///
/// Protótipo: `ModalSistema.dc.html`, bloco "MOVER PARA…". Balão de 300 nascido
/// no botão da barra do leitor, **sem véu**: `padding: 8px`, a busca em cima
/// como campo de 14 com a lupa, as seções em versalete de 10,5, as linhas em
/// 13,5 com o ícone de pasta, e no pé uma linha de um pixel com a frase dos
/// atalhos — `↩ move · esc fecha · dá para desfazer com ⌘Z`.
///
/// Essa última frase é a peça que faltava: mover **é** reversível, e dizer isso
/// no próprio balão é o que dispensa a pergunta "tem certeza?" que o desenho
/// reserva ao irreversível. Ver `SwipeUndoBand`.
///
/// **Sem os números de mensagem por pasta** que o protótipo mostra (214, 86):
/// `ContextMenuItem` não os carrega, e inventá-los seria pior do que não
/// mostrá-los. Está no relatório.
struct MoveFolderPanel: View {
    @Environment(\.theme) private var theme

    static var visibleRows: Int { MenuSurface.visibleRows }
    static var rowHeight: CGFloat { 32 }
    static let headerHeight: CGFloat = 24
    /// `width: 300px`, do protótipo.
    static let width: CGFloat = Theme.ModalWidth.folderPopover
    static var listMaxHeight: CGFloat { CGFloat(visibleRows) * rowHeight }

    let groups: [MoveFolderGroup]
    let onPick: (ContextCommand) -> Void

    @State private var query = ""
    @State private var hovering: String?

    static func groups(from entries: [ContextMenuEntry]) -> [MoveFolderGroup] {
        entries.compactMap { entry in
            switch entry {
            case .submenu(let title, let items):
                return MoveFolderGroup(title: title, items: items)
            case .item(let item):
                return MoveFolderGroup(title: "", items: [item])
            // Legenda é cabeçalho do menu do link; a lista de pastas não tem
            // nenhuma, e traço aqui nunca virou grupo.
            case .separator, .legenda, .aviso:
                return nil
            }
        }
    }

    private var filtered: [MoveFolderGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            let items = group.items.filter {
                $0.title.localizedCaseInsensitiveContains(needle)
            }
            return items.isEmpty ? nil : MoveFolderGroup(title: group.title, items: items)
        }
    }

    private var itemCount: Int { filtered.reduce(0) { $0 + $1.items.count } }

    private var listHeight: CGFloat {
        let headers = filtered.reduce(0) { $0 + ($1.title.isEmpty ? 0 : 1) }
        let content = CGFloat(itemCount) * Self.rowHeight
            + CGFloat(headers) * Self.headerHeight
        return min(max(content, Self.rowHeight), Self.listMaxHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            busca
            if filtered.isEmpty {
                Text(groups.isEmpty
                     ? L10n.tr("Sincronize a conta para ver pastas e marcadores.")
                     : L10n.tr("Nenhuma pasta com esse nome."))
                    .font(theme.sans.font(size: 13.5))
                    .foregroundStyle(theme.ink3.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { group in
                            if !group.title.isEmpty {
                                ModalEyebrow(text: group.title, size: 10.5, tracking: 0.06)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 4)
                                    .padding(.bottom, 3)
                                    .frame(height: Self.headerHeight, alignment: .bottomLeading)
                            }
                            ForEach(group.items, id: \.self) { item in
                                row(item, in: group)
                            }
                        }
                    }
                }
                .frame(height: listHeight)
            }
            atalhos
        }
        .padding(8)
        .frame(width: Self.width)
        .background(theme.modalSheet.color)
    }

    /// `padding: 9px 12px`, lupa de 15 e o texto de 14. O rótulo é a ação
    /// ("Mover para…"), e não "Buscar": o campo é a porta do balão.
    private var busca: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(theme.ink3.color)
                .frame(width: 15)
                .accessibilityHidden(true)
            TextField(L10n.tr("Mover para…"), text: $query)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 14))
                .foregroundStyle(theme.ink.color)
                .accessibilityLabel(L10n.tr("Buscar pasta"))
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            theme.modalField.color,
            in: RoundedRectangle(cornerRadius: theme.modalButtonRadius, style: .continuous)
        )
        .padding(.bottom, 6)
    }

    private func row(_ item: ContextMenuItem, in group: MoveFolderGroup) -> some View {
        let key = group.title + "\u{1f}" + item.title
        let hot = hovering == key
        return Button {
            onPick(item.command)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(theme.ink3.color)
                    .frame(width: 15)
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(theme.sans.font(size: 13.5))
                    .foregroundStyle(hot ? theme.accentInk.color : theme.ink.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // O `↩` da linha sob o cursor: o desenho o põe na que será
                // movida com Enter, e é essa que o cursor escolhe.
                if hot {
                    Text("↩")
                        .font(theme.mono.font(size: 11))
                        .foregroundStyle(theme.ink3.color)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .menuRowHighlight(hot)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside ? key : (hovering == key ? nil : hovering)
        }
        .accessibilityLabel(item.title)
    }

    /// A linha dos atalhos. Ela diz que a ação **volta**, e é por isso que
    /// mover não pergunta nada.
    private var atalhos: some View {
        Text(L10n.tr("↩ move · esc fecha · dá para desfazer com ⌘Z"))
            .font(theme.sans.font(size: 11.5))
            .foregroundStyle(theme.ink3.color)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairline(theme.modalLine, edges: .top)
            .padding(.top, 6)
    }
}

import SwiftUI
import UNICore
import UNIDesign

/// Um bloco do painel "Mover para pasta" — o título da seção e as pastas.
struct MoveFolderGroup: Identifiable, Hashable {
    var id: String { title }
    let title: String
    let items: [ContextMenuItem]
}

/// O painel nosso no lugar do `Menu` do sistema. A lista do Gmail tem dezenas
/// de marcadores; o submenu nativo ocupava a tela inteira. Aqui cabem
/// **20 linhas** e o resto rola.
struct MoveFolderPanel: View {
    @Environment(\.theme) private var theme

    static var visibleRows: Int { MenuSurface.visibleRows }
    static var rowHeight: CGFloat { MenuSurface.listRowHeight }
    static let headerHeight: CGFloat = 22
    static let width: CGFloat = 280
    static var listMaxHeight: CGFloat { MenuSurface.listMaxHeight }

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
        VStack(alignment: .leading, spacing: 6) {
            TextField(L10n.tr("Buscar pasta…"), text: $query)
                .textFieldStyle(.plain)
                .font(theme.sans.font(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(theme.surface2.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .accessibilityLabel(L10n.tr("Buscar pasta"))

            if filtered.isEmpty {
                Text(groups.isEmpty
                     ? L10n.tr("Sincronize a conta para ver pastas e marcadores.")
                     : L10n.tr("Nenhuma pasta com esse nome."))
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(theme.ink3.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { group in
                            if !group.title.isEmpty {
                                Text(group.title)
                                    .capsLabel()
                                    .padding(.horizontal, MenuSurface.rowHorizontalPadding)
                                    .padding(.top, 6)
                                    .padding(.bottom, 4)
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
        }
        .padding(8)
        .frame(width: Self.width)
        .background(theme.surface.color)
    }

    private func row(_ item: ContextMenuItem, in group: MoveFolderGroup) -> some View {
        let key = group.title + "\u{1f}" + item.title
        let hot = hovering == key
        return Button {
            onPick(item.command)
        } label: {
            Text(item.title)
                .font(theme.sans.font(size: MenuSurface.rowFontSize))
                .foregroundStyle(hot ? theme.accentInk.color : theme.ink.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, MenuSurface.rowHorizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Self.rowHeight)
                .menuRowHighlight(hot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside ? key : (hovering == key ? nil : hovering)
        }
        .accessibilityLabel(item.title)
    }
}

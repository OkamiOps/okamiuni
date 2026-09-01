import SwiftUI
import UNICore
import UNIDesign

/// O estado de **um nível** de menu aberto: as entradas, qual linha está
/// realçada e onde cada linha caiu.
///
/// É classe, e não `@State` dentro da `View`, porque quem manda no realce não é
/// só o ponteiro: as setas do teclado chegam por um monitor de eventos do
/// AppKit, fora da árvore SwiftUI, e o submenu é **outra janela** que precisa
/// saber em que altura a linha do pai está. Estado que dois donos escrevem tem
/// de ter um lugar só.
///
/// `rowTops` é em pontos, no espaço do painel, **y para baixo** — o espaço do
/// SwiftUI. Quem converte para a tela é o `ContextMenuPresenter`, que é o único
/// que conhece a moldura da janela.
@MainActor
@Observable
final class MenuLevel {
    let entries: [ContextMenuEntry]
    var highlighted: Int?
    /// Não observa: cada scroll mexia nestes números, o painel redesenhava e a
    /// lista voltava ao topo — o "scroll quebrado" do submenu de pastas.
    @ObservationIgnored
    var rowTops: [Int: CGFloat] = [:]
    /// Só as setas pedem `scrollTo`. O ponteiro, não: o item sob o cursor
    /// muda ao rolar, e seguir o realce puxava a lista de volta.
    @ObservationIgnored
    var followHighlight = false

    init(entries: [ContextMenuEntry], highlighted: Int? = nil) {
        self.entries = entries
        self.highlighted = highlighted
    }

    /// A entrada realçada, se houver.
    var highlightedEntry: ContextMenuEntry? {
        guard let highlighted, entries.indices.contains(highlighted) else { return nil }
        return entries[highlighted]
    }

    /// Move o realce com ↑ / ↓, pulando traço e item apagado.
    func move(_ step: Int) {
        followHighlight = true
        highlighted = MenuKeyNavigation.next(after: highlighted, step: step, in: entries)
    }

    /// Realce do ponteiro: pinta a linha e **não** arrasta o scroll.
    func hover(_ row: Int) {
        followHighlight = false
        highlighted = row
    }
}

/// O painel de menu, desenhado por nós.
///
/// ## O que ele substitui
///
/// O `contextMenu` do SwiftUI monta um `NSMenu`: fundo cinza do sistema, realce
/// rosa do sistema, tipografia do sistema — em cima de uma interface que
/// desenha todos os dropdowns no idioma do design. O dono do projeto mandou o
/// print e a decisão de "menu de contexto é do sistema" foi revogada (Task AN).
///
/// ## O que ele **não** decide
///
/// Nada de conteúdo. A lista de entradas é dado, vem de `UNICore.ContextMenus`
/// e tem teste lá. Aqui só se pinta, e a pintura inteira sai de `Theme`.
struct ContextMenuPanel: View {
    @Environment(\.theme) private var theme

    /// O painel não passa disto; rótulo maior trunca. Um menu que fica mais
    /// largo que a coluna que o abriu deixa de parecer parte da tela.
    static let maxWidth: CGFloat = 320
    static let minWidth: CGFloat = 176

    let level: MenuLevel
    var onHover: (Int) -> Void = { _ in }
    var onActivate: (Int) -> Void = { _ in }

    var body: some View {
        Group {
            if Self.needsScroll(level.entries) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            rows
                        }
                    }
                    .scrollIndicators(.visible)
                    .frame(height: MenuSurface.listMaxHeight)
                    .onChange(of: level.highlighted) { _, row in
                        guard level.followHighlight, let row else { return }
                        level.followHighlight = false
                        proxy.scrollTo(row, anchor: .center)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    rows
                }
            }
        }
        .frame(minWidth: Self.minWidth - 2 * MenuSurface.panelPadding, alignment: .leading)
        .frame(maxWidth: Self.maxWidth - 2 * MenuSurface.panelPadding, alignment: .leading)
        .menuPanelChrome()
        .coordinateSpace(name: MenuSurface.panelSpace)
    }

    /// Acima disto o painel vira lista com scroll — o mesmo teto do
    /// "Mover para pasta" da barra do leitor.
    static func needsScroll(_ entries: [ContextMenuEntry]) -> Bool {
        entries.filter {
            if case .separator = $0 { return false }
            return true
        }.count > MenuSurface.visibleRows
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(Array(level.entries.enumerated()), id: \.offset) { index, entry in
            row(index, entry)
                .id(index)
        }
    }

    @ViewBuilder
    private func row(_ index: Int, _ entry: ContextMenuEntry) -> some View {
        switch entry {
        case .separator:
            MenuDivider()
        case .item(let item):
            line(
                index,
                title: item.title,
                trailing: item.shortcut?.label,
                isSubmenu: false,
                isEnabled: item.isEnabled,
                help: item.help
            )
        case .submenu(let title, let children):
            line(
                index,
                title: title,
                trailing: nil,
                isSubmenu: true,
                isEnabled: !children.isEmpty,
                help: nil
            )
        }
    }

    /// Uma linha do menu.
    ///
    /// `Button` e não `onTapGesture`: o `Button` já traz o alvo de toque, o
    /// anel de foco do projeto e a semântica de acessibilidade.
    ///
    /// ## Por que `allowsHitTesting` e não `.disabled`
    ///
    /// `.disabled` desliga o clique **e apaga o botão sozinho**, com a opacidade
    /// que o SwiftUI escolhe. Quer dizer: quem decidiria a aparência do item
    /// apagado voltaria a ser o sistema, no meio da tarefa que tirou o sistema
    /// do menu — e, medido, o apagado do sistema por cima do nosso escondia o
    /// defeito: com a tinta `ink4` **arrancada** do código, o teste de pixel
    /// continuava passando, porque a opacidade do SwiftUI apagava o rótulo do
    /// mesmo jeito. Provado por mutação, é o teste decorativo que a revisão de
    /// ontem condenou doze vezes.
    ///
    /// Aqui o clique morre em `allowsHitTesting` e na guarda da ação, e o
    /// apagado é o token — que é o que o teste consegue afirmar.
    private func line(
        _ index: Int,
        title: String,
        trailing: String?,
        isSubmenu: Bool,
        isEnabled: Bool,
        help: String?
    ) -> some View {
        let isHot = isEnabled && level.highlighted == index
        return Button {
            guard isEnabled else { return }
            onActivate(index)
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(theme.sans.font(size: MenuSurface.rowFontSize))
                    .foregroundStyle(tint(isEnabled: isEnabled, isHot: isHot))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(theme.sans.font(size: MenuSurface.hintFontSize))
                        .foregroundStyle(hint(isEnabled: isEnabled, isHot: isHot))
                }
                if isSubmenu {
                    Text("▸")
                        .font(.system(size: 8))
                        .foregroundStyle(hint(isEnabled: isEnabled, isHot: isHot))
                }
            }
            .padding(.horizontal, MenuSurface.rowHorizontalPadding)
            .padding(.vertical, MenuSurface.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .menuRowHighlight(isHot)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isEnabled)
        // O balão do item apagado. Sem ele o rótulo em `ink4` é só um item
        // quebrado aos olhos de quem lê — e "item desabilitado diz por quê" é
        // a regra que a Task AR tornou explícita.
        //
        // `allowsHitTesting(false)` não desliga o `help`: o balão do AppKit
        // sai da área de rastreio da `NSView`, não do teste de acerto do
        // SwiftUI. Medido no app.
        .help(help ?? "")
        .focusRing(cornerRadius: theme.radiusSmall)
        // Item apagado não recebe realce nem por ponteiro: `onHover` só avisa
        // quando há o que realçar.
        .onHover { inside in
            guard isEnabled, inside else { return }
            onHover(index)
        }
        // A altura da linha é o que ancora o submenu. Medida, não estimada: o
        // corpo do rótulo muda com o tema, e uma constante aqui mandaria o
        // submenu para o lugar errado no primeiro tema de fonte maior.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(MenuSurface.panelSpace)).minY
        } action: { top in
            level.rowTops[index] = top
        }
    }

    /// A tinta do rótulo. Apagado é `ink4` — o mesmo token do rótulo de uma
    /// coluna de arraste que não faz nada.
    private func tint(isEnabled: Bool, isHot: Bool) -> Color {
        if !isEnabled { return theme.ink4.color }
        return isHot ? theme.accentInk.color : theme.ink.color
    }

    private func hint(isEnabled: Bool, isHot: Bool) -> Color {
        if !isEnabled { return theme.ink4.color }
        return isHot ? theme.accentInk.color : theme.ink3.color
    }
}

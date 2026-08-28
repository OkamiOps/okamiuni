import AppKit
import SwiftUI
import UNICore
import UNIDesign

/// O `<select>` do protótipo, desenhado por nós.
///
/// ## O defeito que isto conserta
///
/// A barra usava `Picker(...).pickerStyle(.menu)`, que é um `NSPopUpButton`: o
/// controle fechado vem com a moldura e a seta do macOS, e não com a do design.
/// O dono do projeto relatou "tem vários dropdown usando o padrao do sistema em
/// vez de custom", e é exatamente esse o desencontro.
///
/// O protótipo desenha o controle fechado assim (linha 2671 do `.dc.html`):
/// `appearance: none; border: none; background: transparent; color: var(--ink);
/// font: var(--sans) 11.5px/550; padding: 0 17px 0 9px`, dentro do `segWrap`,
/// com um `▼` de 7px em `--ink4` a 6px da direita. É o que este arquivo pinta.
///
/// ## O que o protótipo **não** desenha, e o que isso implicou
///
/// Vale registrar, porque a especificação da tarefa dizia o contrário: o menu
/// que um `<select>` abre é o do sistema, em qualquer navegador — `appearance:
/// none` estiliza o controle fechado e mais nada. O protótipo não tem menu
/// próprio para fonte, corpo, conta ou rascunho sugerido.
///
/// O que ele **tem** é o seletor de tema (linha 328): um `div` de gatilho com o
/// mesmo `▼` e um painel absoluto de `width: 300px; max-height: 420px;
/// overflow-y: auto`, desenhado por ele. É esse o menu próprio do design, e é
/// dele que este componente copia o painel — inclusive o teto de 420, que é o
/// que impede a lista de fontes do sistema de virar uma coluna infinita.
///
/// ## Por que `popover` e não `overlay`
///
/// Um `overlay` vive dentro da janela e é recortado por ela. A lista de fontes
/// instaladas mede ~420pt; aberta a partir de uma barra que fica a 200pt do
/// topo de uma janela de 620, metade dela cairia fora. O `popover` é uma janela
/// própria: passa por cima da borda, e por construção não pode ser decepado por
/// irmão nenhum — o defeito de empilhamento que esta mesma tarefa consertou nas
/// listas de contato não tem como acontecer aqui.
///
/// Ele custa uma coisa, registrada para quem for verificar: o `Render` desenha
/// numa janela fora da tela que nunca é a janela-chave, e um `popover` não
/// abre ali. O que se verifica no harness é o **controle fechado**, que é o que
/// o dono relatou; o conteúdo do menu é verificado no catálogo puro, em
/// `FontCatalogTests`.
struct ComposerSelect: View {
    @Environment(\.theme) private var theme

    struct Option: Identifiable, Hashable, Sendable {
        var id: String { value }
        let value: String
        let label: String
        /// Desenha o rótulo na própria família — só o menu de fonte usa.
        var previewFamily: String?

        init(value: String, label: String, previewFamily: String? = nil) {
            self.value = value
            self.label = label
            self.previewFamily = previewFamily
        }
    }

    /// Um bloco do menu, com o versalete que o encabeça. O separador entre
    /// blocos é a divisória; um bloco sem título não desenha cabeçalho.
    struct Group: Identifiable, Sendable {
        var id: String { title ?? "—" }
        var title: String?
        var options: [Option]
    }

    /// O que o `help` diz — o mesmo `title` do `<select>` do protótipo.
    let title: String
    /// Nulo quando a seleção mistura dois valores. O controle escreve "—" em
    /// vez de mentir apontando o primeiro.
    let selected: String?
    /// Protótipo: 112pt na fonte, 54 no corpo, e o "De" da tela 06 se mede pelo
    /// conteúdo.
    var width: CGFloat?
    let groups: [Group]
    let pick: (String) -> Void

    @State private var open = false

    /// Protótipo: `font-size: 11.5px; font-weight: 550`.
    var labelSize: CGFloat = 11.5
    /// Protótipo: `padding: 0 17px 0 9px` na fonte e no corpo, `0 26px 0 10px`
    /// na conta. Só o recuo da **esquerda** é parâmetro: o da direita, nos dois,
    /// é a folga que o `▼` ocupa, e aqui o `▼` é um item de verdade da linha, a
    /// 6pt da borda. Repetir o número seria somá-lo duas vezes.
    var leadingPadding: CGFloat = 9

    private var currentLabel: String {
        guard let selected else { return "—" }
        for group in groups {
            if let hit = group.options.first(where: { $0.value == selected }) { return hit.label }
        }
        // Uma escolha que não está em nenhum bloco ainda tem de aparecer: é o
        // caso de um rascunho guardado com uma fonte que foi desinstalada.
        return selected
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 0) {
                Text(currentLabel)
                    .font(theme.sans.font(size: labelSize, weight: .medium))  // CSS 550
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Num controle de largura fixa a folga cede ao rótulo, que
                // trunca; num de largura livre ela é o que separa o texto do
                // `▼`, e vale a folga do protótipo.
                Spacer(minLength: width == nil ? 10 : 4)
                Text("▼")
                    .font(.system(size: 7))
                    .foregroundStyle(theme.ink4.color)
            }
            .padding(.leading, leadingPadding)
            .padding(.trailing, 6)
            .frame(width: width, alignment: .leading)
            // Protótipo: `height: 25px` dentro de um `segWrap` de 26 — o
            // controle não desenha moldura nenhuma, ela é do grupo.
            .frame(height: 25)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(in: Rectangle())
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(currentLabel)
        .popover(isPresented: $open, arrowEdge: .bottom) { panel }
    }

    /// Protótipo, o painel do seletor de tema: `max-height: 420px;
    /// overflow-y: auto; padding: 8px; border-radius: var(--r3);
    /// background: var(--surface)`.
    ///
    /// `LazyVStack` e não `VStack`: a lista de fontes instaladas tem centenas de
    /// linhas, e cada linha desenha o próprio rótulo na própria face. Montar
    /// todas de uma vez seria carregar centenas de fontes para mostrar dez.
    private var panel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    // A divisória e o realce da linha são os mesmos do menu de
                    // contexto — ver `MenuSurface`. Eram desenhados à mão aqui
                    // até a Task AN; compartilhados, os dois painéis não têm
                    // como divergir no primeiro conserto.
                    if index > 0 { MenuDivider() }
                    if let title = group.title {
                        Text(title)
                            .capsLabel()
                            .padding(.horizontal, 8)
                            .padding(.top, index == 0 ? 2 : 0)
                            .padding(.bottom, 4)
                    }
                    ForEach(group.options) { option in
                        row(option)
                    }
                }
            }
            .padding(8)
        }
        .frame(width: 232)
        .frame(maxHeight: 420)
        .background(theme.surface.color)
    }

    private func row(_ option: Option) -> some View {
        let isSelected = option.value == selected
        return Button {
            pick(option.value)
            open = false
        } label: {
            HStack(spacing: 8) {
                Text(option.label)
                    .font(rowFont(option))
                    .foregroundStyle(isSelected ? theme.accentInk.color : theme.ink.color)
                    .lineLimit(1)
                Spacer(minLength: 4)
                // O visto marca a escolha atual. Sem ele, um menu de trezentas
                // linhas abre e não diz qual delas está valendo — o fundo do
                // acento sozinho some assim que a lista rola.
                if isSelected {
                    Text("✓")
                        .font(theme.sans.font(size: 10, weight: .bold))
                        .foregroundStyle(theme.accentInk.color)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .menuRowHighlight(isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
    }

    /// O rótulo de uma fonte é desenhado **na própria fonte**: é assim que se
    /// escolhe uma face numa lista de centenas, e é o que qualquer editor faz.
    /// Os outros menus não pedem face nenhuma e ficam no sans do tema.
    private func rowFont(_ option: Option) -> Font {
        guard let family = option.previewFamily else {
            return theme.sans.font(size: 12.5)
        }
        return ComposerFormatting.family(family, theme: theme).font(size: 12.5)
    }
}

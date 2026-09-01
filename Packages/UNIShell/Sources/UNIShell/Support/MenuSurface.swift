import SwiftUI
import UNIDesign

/// O idioma visual de **todo painel que se abre por cima** — o dropdown do
/// composer e o menu de contexto.
///
/// ## Por que compartilhado, e não copiado
///
/// O painel do `ComposerSelect` já passou pelo crivo do dono do projeto: fundo
/// `surface`, raio `--r3`, linha em hairline, realce da linha em `accentSoft`
/// com a tinta em `accentInk`, divisória em `line2`. Quando o menu de contexto
/// deixou o `NSMenu` (Task AN), copiar esses números para um segundo arquivo
/// era o caminho curto — e é exatamente assim que dois `.stroke` borrados
/// sobreviveram um marco inteiro nesta base, cada um num arquivo que ninguém
/// lembrava ser o mesmo desenho. As medidas moram aqui uma vez.
///
/// Tudo sai de `Theme`. Nenhuma cor literal: são 26 temas, e o menu tem de
/// virar com todos.
enum MenuSurface {
    /// Protótipo, painel do seletor de tema: `padding: 8px`. O menu de contexto
    /// é mais apertado — linhas curtas, muitas — e usa 6.
    static let panelPadding: CGFloat = 6
    static let rowHorizontalPadding: CGFloat = 8
    static let rowVerticalPadding: CGFloat = 5
    /// Folga em volta da divisória entre blocos.
    static let dividerPadding: CGFloat = 5
    /// Quantas pastas/linhas cabem na janela do menu antes de rolar. A lista
    /// de marcadores do Gmail passa fácil de cem; sem teto o painel come a tela.
    static let visibleRows = 20
    static let listRowHeight: CGFloat = 26
    static var listMaxHeight: CGFloat { CGFloat(visibleRows) * listRowHeight }

    /// O corpo de uma linha de menu.
    static let rowFontSize: CGFloat = 12.5
    /// O atalho e a seta do submenu, um degrau abaixo do rótulo.
    static let hintFontSize: CGFloat = 11
    /// O espaço de coordenadas em que a altura de cada linha do menu é medida.
    ///
    /// Mora aqui, e não dentro da `View`, porque `View` é `@MainActor` implícito
    /// e um `static` de lá não pode ser lido do fechamento `Sendable` que o
    /// `onGeometryChange` recebe.
    static let panelSpace = "uni.menu.panel"
}

/// A divisória entre blocos de um painel — um pixel do dispositivo em `line2`.
///
/// Era desenhada à mão dentro do `ComposerSelect`; virou tipo quando o menu de
/// contexto passou a precisar dela para `ContextMenuEntry.separator`.
struct MenuDivider: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(theme.line2.color)
            .frame(height: Hairline.thickness(displayScale))
            .padding(.vertical, MenuSurface.dividerPadding)
    }
}

/// O realce de uma linha de painel: fundo `accentSoft` no raio pequeno.
///
/// A tinta do texto é do chamador (`accentInk` quando realçado) porque quem
/// desenha a linha também decide o que fazer com um item apagado, e engolir
/// essa escolha aqui deixaria o estado desabilitado sem lugar.
private struct MenuRowHighlight: ViewModifier {
    @Environment(\.theme) private var theme
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .background(isOn ? theme.accentSoft.color : .clear)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
    }
}

extension View {
    func menuRowHighlight(_ isOn: Bool) -> some View {
        modifier(MenuRowHighlight(isOn: isOn))
    }
}

/// A moldura do painel de menu de contexto: fundo `surface`, raio `--r3`,
/// borda de um pixel em `line` e a sombra do tema.
///
/// `strokeBorder`, nunca `.stroke`: o traçado do `.stroke` fica metade para
/// fora da forma e sai lavado em 1×. É o defeito que a Task AC caçou nos
/// últimos dois lugares onde ele ainda vivia, e que `HairlineThicknessTests`
/// agora tranca.
private struct MenuPanelChrome: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content
            .padding(MenuSurface.panelPadding)
            .background(theme.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusLarge)
                    .strokeBorder(
                        theme.line.color,
                        lineWidth: Hairline.thickness(displayScale)
                    )
            }
            .shadow(theme.shadow)
    }
}

extension View {
    func menuPanelChrome() -> some View { modifier(MenuPanelChrome()) }
}

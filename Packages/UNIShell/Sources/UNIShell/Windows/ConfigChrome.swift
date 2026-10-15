import SwiftUI
import UNICore
import UNIDesign

// MARK: - A paleta da janela de Configurações

/// Os papéis de cor que o desenho de `Config.dc.html` usa, resolvidos a partir
/// do tema ativo.
///
/// O mock tem três colunas de tokens (`claro`, `escuro`, `classico`) e elas
/// não são três desenhos: são o **mesmo** desenho com dois acabamentos de
/// superfície. Vidro e Vidro Noite ganham o vidro; os 26 clássicos recebem
/// painéis sólidos vindos dos próprios tokens deles. É por isso que esta
/// estrutura nasce de `Theme` e não de um `if tema == ...`: qualquer um dos 28
/// temas atravessa a mesma montagem.
struct ConfigPalette {
    let theme: Theme

    init(_ theme: Theme) { self.theme = theme }

    /// `card` / `cardEdge`: a única caixa elevada de uma página.
    var card: TokenColor { theme.glassCard }
    var cardEdge: TokenColor { theme.glassCardEdge }
    var cardShadow: [ShadowToken] { theme.shadow }

    /// `tile` / `tileEdge`: o azulejo raso, o que lê como recorte do painel.
    var tile: TokenColor { theme.glassTile }
    var tileEdge: TokenColor { theme.glassTileEdge }

    /// `field`: a calha de um campo, de um segmentado ou de um seletor.
    var field: TokenColor { theme.isTranslucent ? theme.glassTile : theme.surface2 }

    /// `navOn` / `segOn`: o item escolhido, dentro do painel.
    var navOn: TokenColor { theme.isTranslucent ? theme.glassActive : theme.surface3 }
    var segOn: TokenColor { theme.isTranslucent ? theme.glassActive : theme.surface }
    /// O relevo do segmento escolhido no claro do mock
    /// (`0 1px 3px rgba(30,30,80,0.14)`). Nos temas escuros o mock não o pinta.
    var segShadow: [ShadowToken] {
        theme.isDark
            ? []
            : [ShadowToken(x: 0, y: 1, blur: 3, color: TokenColor(red: 30 / 255, green: 30 / 255, blue: 80 / 255, opacity: 0.14))]
    }

    /// `btn2`: o botão secundário — borda de linha e fundo de superfície.
    var btn2: TokenColor { theme.isTranslucent ? theme.glassCard : theme.surface }
    var btnGlow: [ShadowToken] { theme.btnShadow }

    /// `ring`: o que está atrás dos avatares sobrepostos.
    var ring: TokenColor { theme.glassRing }

    var ink: TokenColor { theme.ink }
    var ink2: TokenColor { theme.ink2 }
    var ink3: TokenColor { theme.ink3 }
    var line: TokenColor { theme.line }
    var accent: TokenColor { theme.accent }
    var accentInk: TokenColor { theme.accentInk }
    var accentSoft: TokenColor { theme.accentSoft }
    var onAccent: TokenColor { theme.onAccent }
    var green: TokenColor { theme.success }
    var red: TokenColor { theme.danger }
    var orange: TokenColor { theme.warning }

    /// `off`: a calha de um interruptor desligado. O mock escreve
    /// `rgba(20,20,50,0.14)` no claro e `rgba(255,255,255,0.16)` no escuro —
    /// a mesma ideia da `line`, com mais corpo.
    var off: TokenColor {
        theme.isDark
            ? TokenColor(red: 1, green: 1, blue: 1, opacity: 0.16)
            : TokenColor(red: 20 / 255, green: 20 / 255, blue: 50 / 255, opacity: 0.14)
    }
}

extension EnvironmentValues {
    /// A paleta resolvida, para as subviews não a remontarem a cada corpo.
    @Entry var configPalette: ConfigPalette = ConfigPalette(.default)
}

// MARK: - Medidas literais do mock

/// As medidas de `Config.dc.html`, com o nome que elas têm lá.
enum ConfigMetrics {
    /// `padding: 10px` da janela e `gap: 10px` entre os dois painéis.
    static let windowPadding: CGFloat = 10
    static let panelGap: CGFloat = 10
    /// `grid-template-columns: 244px minmax(0, 1fr)`.
    static let navWidth: CGFloat = 244
    /// `border-radius: 18px` dos dois painéis.
    static let panelRadius: CGFloat = 18
    /// `padding: 28px 40px 24px` do painel de conteúdo.
    static let mainTop: CGFloat = 28
    static let mainSide: CGFloat = 40
    static let mainBottom: CGFloat = 24
    /// `max-width: 880px` das páginas de uma coluna.
    static let contentMaxWidth: CGFloat = 880
    /// `column-gap: 44px` das páginas de duas colunas.
    static let columnGap: CGFloat = 44
}

// MARK: - O painel

/// Um dos dois painéis flutuantes da janela.
///
/// No Vidro é `glassPanel`, que já sabe pintar o vidro, a aresta de luz e a
/// sombra. Nos 26 clássicos o mesmo retângulo é **opaco**: `glass: #0B0B12`
/// com `edge: #252636` no mock, que aqui são `surface` e `line` do tema. Sem
/// desfoque, sem gradiente, mesma estrutura.
struct ConfigPanel: ViewModifier {
    @Environment(\.displayScale) private var displayScale
    let theme: Theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ConfigMetrics.panelRadius, style: .continuous)
        if theme.isTranslucent {
            content.glassPanel(theme)
        } else {
            content
                .background(theme.surface.color)
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(theme.line.color, lineWidth: Hairline.thickness(displayScale))
                }
                .shadow(theme.shadow)
        }
    }
}

extension View {
    func configPanel(_ theme: Theme) -> some View { modifier(ConfigPanel(theme: theme)) }

    /// `background: {{t.card}}; border: 1px solid {{t.cardEdge}}; border-radius: R;
    /// box-shadow: {{t.cardShadow}}` — a caixa elevada do mock.
    func configCard(_ palette: ConfigPalette, radius: CGFloat = 16) -> some View {
        modifier(ConfigSurface(palette: palette, radius: radius, elevated: true))
    }

    /// `background: {{t.tile}}; border: 1px solid {{t.tileEdge}}` — o azulejo raso.
    func configTile(_ palette: ConfigPalette, radius: CGFloat = 14) -> some View {
        modifier(ConfigSurface(palette: palette, radius: radius, elevated: false))
    }
}

struct ConfigSurface: ViewModifier {
    @Environment(\.displayScale) private var displayScale
    let palette: ConfigPalette
    let radius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background((elevated ? palette.card : palette.tile).color, in: shape)
            .overlay {
                shape.strokeBorder(
                    (elevated ? palette.cardEdge : palette.tileEdge).color,
                    lineWidth: Hairline.thickness(displayScale)
                )
            }
            .modifier(ConditionalShadow(layers: elevated ? palette.cardShadow : []))
    }
}

struct ConditionalShadow: ViewModifier {
    let layers: [ShadowToken]
    func body(content: Content) -> some View {
        if layers.isEmpty { content } else { content.shadow(layers) }
    }
}

// MARK: - O cabeçalho da página

/// `header` do mock: avatar opcional de 46, título de 27/700 com
/// `letter-spacing: -0.025em`, subtítulo de 14 em `ink3`, e uma ação à direita.
struct ConfigPageHeader: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette

    let title: String
    let subtitle: String
    var avatarInitial: String?
    var avatarTint: TokenColor?
    var action: (label: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let avatarInitial {
                Text(avatarInitial)
                    .font(theme.sans.font(size: 18, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 46, height: 46)
                    .background((avatarTint ?? palette.accent).color, in: Circle())
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(theme.sans.font(size: 27, weight: .bold))
                    .tracking(-0.025 * 27)
                    .foregroundStyle(palette.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(theme.sans.font(size: 14))
                    .foregroundStyle(palette.ink3.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(.plain)
                    .configPrimaryButton(palette, font: theme.sans.font(size: 13, weight: .semibold))
            }
        }
        .padding(.bottom, 20)
    }
}

// MARK: - Botões

extension View {
    /// `background: {{t.accent}}; color: {{t.onAccent}}; border-radius: 10px;
    /// padding: 10px 16px; font-size: 13px; font-weight: 600; box-shadow: {{t.btnGlow}}`.
    func configPrimaryButton(
        _ palette: ConfigPalette,
        font: Font,
        radius: CGFloat = 10,
        horizontal: CGFloat = 16,
        vertical: CGFloat = 10
    ) -> some View {
        self
            .font(font)
            .foregroundStyle(palette.onAccent.color)
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(palette.accent.color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .modifier(ConditionalShadow(layers: palette.btnGlow))
            .focusRing(cornerRadius: radius)
    }

    /// `background: {{t.btn2}}; border: 1px solid {{t.line}}` — o botão calmo.
    func configQuietButton(
        _ palette: ConfigPalette,
        font: Font,
        radius: CGFloat = 9,
        horizontal: CGFloat = 12,
        vertical: CGFloat = 7
    ) -> some View {
        modifier(ConfigQuietButton(
            palette: palette, font: font, radius: radius,
            horizontal: horizontal, vertical: vertical
        ))
    }
}

struct ConfigQuietButton: ViewModifier {
    @Environment(\.displayScale) private var displayScale
    let palette: ConfigPalette
    let font: Font
    let radius: CGFloat
    let horizontal: CGFloat
    let vertical: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .font(font)
            .foregroundStyle(palette.ink.color)
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(palette.btn2.color, in: shape)
            .overlay { shape.strokeBorder(palette.line.color, lineWidth: Hairline.thickness(displayScale)) }
            .focusRing(cornerRadius: radius)
    }
}

// MARK: - A linha de ajuste

/// A linha que o mock repete em Aparência, Conta e Inteligência: rótulo de 14
/// em peso 500, nota de 12,5 em `ink3`, controle à direita, e uma `line` de um
/// pixel separando uma linha da seguinte.
struct ConfigRow<Control: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale

    let label: String
    var note: String?
    /// Onde a linha de um pixel encosta. O mock usa `border-top` nas listas e
    /// `border-bottom` nas pilhas de ajuste.
    var divider: Edge.Set = .top
    var verticalPadding: CGFloat = 13
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(theme.sans.font(size: 14, weight: .medium))
                    .foregroundStyle(palette.ink.color)
                if let note {
                    Text(note)
                        .font(theme.sans.font(size: 12.5))
                        .foregroundStyle(palette.ink3.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity)
        .overlay(alignment: divider.contains(.top) ? .top : .bottom) {
            Rectangle()
                .fill(palette.line.color)
                .frame(height: Hairline.thickness(displayScale))
        }
    }
}

// MARK: - O segmentado

/// `span` com calha de `field`, `padding: 2px`, `border-radius: 9px`, e cada
/// opção em `padding: 4px 13px; border-radius: 7px`.
struct ConfigSegmented<Value: Hashable>: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale

    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var fontSize: CGFloat = 12.5
    var horizontal: CGFloat = 13
    var vertical: CGFloat = 4
    /// Cada opção pode ter o seu próprio corpo de letra — é o que o mock faz
    /// no "Tamanho do texto", onde Menor/Padrão/Maior são amostras do efeito.
    var sizes: [CGFloat]?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let chosen = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(theme.sans.font(
                            size: sizes?[index] ?? fontSize,
                            weight: chosen ? .semibold : .medium
                        ))
                        .foregroundStyle((chosen ? palette.ink : palette.ink2).color)
                        // Os enums reais têm quatro e cinco opções onde o mock
                        // desenhou três. Uma linha só, encolhendo o corpo da
                        // letra antes de quebrar — quebrar punha "Automátic/o"
                        // em duas linhas e desalinhava a fileira inteira.
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, horizontal)
                        .padding(.vertical, vertical)
                        .frame(minHeight: 20)
                        .background {
                            if chosen {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(palette.segOn.color)
                                    .modifier(ConditionalShadow(layers: palette.segShadow))
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(palette.field.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(palette.line.color, lineWidth: Hairline.thickness(displayScale))
        }
    }
}

// MARK: - O interruptor

/// `width: 38px; height: 22px; border-radius: 11px`, com o botão de 18 em 2 ou
/// 18 pontos. É desenhado, e não `Toggle(.switch)`, porque o do sistema tem
/// outra medida e outro raio — e a página inteira é medida contra o mock.
struct ConfigSwitch: View {
    @Environment(\.configPalette) private var palette
    @Binding var isOn: Bool
    var label: String = ""

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill((isOn ? palette.accent : palette.off).color)
                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .padding(2)
            }
            .frame(width: 38, height: 22)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusRing(in: Capsule())
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? L10n.tr("ligado") : L10n.tr("desligado"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Títulos de bloco

/// `h2` das páginas: 13px, peso 600, `ink2`.
struct ConfigBlockTitle: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    let text: String
    var note: String?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(text)
                .font(theme.sans.font(size: 13, weight: .semibold))
                .foregroundStyle(palette.ink2.color)
            if let note {
                Text(note)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.ink3.color)
            }
            Spacer(minLength: 0)
        }
    }
}

/// O seletor em forma de pílula do mock: `background: {{t.field}}; border: 1px
/// solid {{t.line}}; border-radius: 9px; padding: 6px 10px 6px 12px` com o
/// chevron duplo à direita. É um `Menu`, para a escolha ser real.
struct ConfigPicker<Value: Hashable, Label: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale

    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    let accessibilityTitle: String
    var mono = false
    @ViewBuilder var currentLabel: Label

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.label) { selection = option.value }
            }
        } label: {
            HStack(spacing: 8) {
                currentLabel
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.ink3.color)
            }
            .font((mono ? theme.mono : theme.sans).font(size: mono ? 12 : 13))
            .foregroundStyle(palette.ink.color)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(palette.field.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(palette.line.color, lineWidth: Hairline.thickness(displayScale))
            }
        }
        // `.button` + `.plain`: o `borderlessButton` desenha o bezel dele por
        // cima e **apaga** o fundo e a borda que o rótulo pinta — era o que
        // deixava a pílula do mock invisível e o texto no azul do sistema.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(accessibilityTitle)
    }
}

extension ConfigPicker where Label == Text {
    init(
        options: [(value: Value, label: String)],
        selection: Binding<Value>,
        accessibilityTitle: String,
        mono: Bool = false
    ) {
        let current = options.first { $0.value == selection.wrappedValue }?.label ?? ""
        self.init(
            options: options,
            selection: selection,
            accessibilityTitle: accessibilityTitle,
            mono: mono
        ) { Text(current) }
    }
}

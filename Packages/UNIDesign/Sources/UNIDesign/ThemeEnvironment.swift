import AppKit
import SwiftUI

extension EnvironmentValues {
    /// The active theme. Defaults to the design's own default so previews and
    /// detached views render correctly without extra setup.
    @Entry public var theme: Theme = .default
}

extension View {
    public func theme(_ theme: Theme) -> some View {
        environment(\.theme, theme)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}

extension View {
    /// Aplica a pilha de sombras de um token. O CSS pinta a primeira camada
    /// por cima, e aqui também: as últimas entram primeiro para ficarem embaixo.
    ///
    /// Camadas `inset` são **ignoradas** aqui de propósito. Elas são brilho
    /// interno, e `.shadow()` do SwiftUI só pinta para fora — desenhá-las aqui
    /// punha um anel em volta do botão, que era o "contorno errado" reclamado.
    /// Quem tem forma própria usa `surface(_:in:)`, que sabe pintá-las por dentro.
    public func shadow(_ layers: [ShadowToken]) -> some View {
        layers.filter { !$0.isInset }.reversed().reduce(AnyView(self)) { view, layer in
            AnyView(
                view.shadow(
                    color: layer.color.color,
                    // SwiftUI não expõe o `spread` do CSS. Somá-lo ao raio é
                    // a aproximação visual correta para os halos de 0,5–1px
                    // dos temas dark; ignorá-lo deixava o hairline exatamente
                    // atrás da própria forma e, portanto, invisível.
                    radius: layer.radius + max(0, layer.spread),
                    x: layer.x,
                    y: layer.y
                )
            )
        }
    }

    /// Pinta a pilha completa de um token sobre uma forma conhecida: as camadas
    /// externas como sombra, as `inset` como brilho por dentro.
    ///
    /// Um `inset 0 1px 0` sem desfoque é uma linha de 1pt encostada na aresta
    /// de cima, por dentro — é isso que dá o relevo sutil dos botões nos temas
    /// escuros. Precisa da forma para recortar, por isso não cabe em `shadow`.
    public func surface<S: InsettableShape>(_ layers: [ShadowToken], in shape: S) -> some View {
        shadow(layers).overlay {
            ZStack {
                ForEach(Array(layers.filter(\.isInset).enumerated()), id: \.offset) { _, layer in
                    shape
                        .stroke(layer.color.color, lineWidth: max(abs(layer.y), 1) * 2)
                        .offset(x: layer.x, y: layer.y)
                        .blur(radius: layer.radius)
                        .clipShape(shape)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// Observable holder for the user's theme choice, persisted across launches.
@MainActor
@Observable
public final class ThemeStore {
    private static let key = "okamiuni.theme"
    private static let typographyKey = "okamiuni.typography-preset"
    private static let followsSystemKey = "okamiuni.theme-follows-system"

    private var baseTheme: Theme
    public private(set) var typographyPreset: TypographyPreset

    /// **Automático**: o Vidro que combina com o claro/escuro do Mac.
    ///
    /// O cartão "Automático · segue o Mac" do desenho de Configurações pede um
    /// terceiro estado que não é um tema: é a ausência de escolha entre os dois
    /// Vidros. Guardá-lo como um `Bool` ao lado do tema — e não como um id de
    /// tema inventado — mantém os 28 temas como eles são e deixa a volta para
    /// um tema fixo sem perder qual era.
    public private(set) var followsSystemAppearance: Bool

    /// O tema exposto para todas as janelas já incorpora a preferência de
    /// leitura. Manter a base separada evita que a escala se acumule ao trocar
    /// de cor ou reiniciar o aplicativo.
    public var theme: Theme { resolvedBase.applyingTypography(typographyPreset) }

    /// O tema antes da escala de leitura: o escolhido, ou o Vidro que segue a
    /// aparência do sistema.
    private var resolvedBase: Theme {
        guard followsSystemAppearance else { return baseTheme }
        return Self.systemIsDark ? .vidroNoite : .vidro
    }

    /// A aparência efetiva do app, lida do AppKit. Fora de um app com
    /// `NSApplication` (testes, previews) ela cai no claro, que é o padrão do
    /// sistema e o que o desenho mostra primeiro.
    private static var systemIsDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.key)
        self.baseTheme = saved.flatMap(Theme.named) ?? .default
        self.typographyPreset = defaults.string(forKey: Self.typographyKey)
            .flatMap(TypographyPreset.init(rawValue:)) ?? .standard
        self.followsSystemAppearance = defaults.bool(forKey: Self.followsSystemKey)
    }

    private let defaults: UserDefaults

    public func select(_ theme: Theme) {
        let selected = Theme.named(theme.id) ?? theme
        self.baseTheme = selected
        defaults.set(selected.id, forKey: Self.key)
        // Escolher um tema é dizer qual: sai do automático sozinho, sem a
        // pessoa ter de desligar um interruptor que ela não viu.
        if followsSystemAppearance { setFollowsSystemAppearance(false) }
    }

    /// Liga ou desliga o "Automático". Ao desligar, o tema volta a ser o que
    /// está resolvido agora — ninguém salta de aparência por desligá-lo.
    public func setFollowsSystemAppearance(_ follows: Bool) {
        if follows {
            followsSystemAppearance = true
        } else {
            let atual = resolvedBase
            followsSystemAppearance = false
            baseTheme = atual
            defaults.set(atual.id, forKey: Self.key)
        }
        defaults.set(followsSystemAppearance, forKey: Self.followsSystemKey)
    }

    /// O id do tema **escolhido**, para o seletor acender a opção certa.
    /// `nil` quando o automático está no comando.
    public var selectedThemeID: String? { followsSystemAppearance ? nil : baseTheme.id }

    /// O interruptor sol/lua do trilho. Troca para o par do tema atual — ver
    /// `Theme.appearanceCounterpart`, que é quem sabe a regra — e grava, como
    /// qualquer outra escolha de tema.
    public func toggleAppearance() {
        select(resolvedBase.appearanceCounterpart)
    }

    /// Para o interruptor desenhar o estado certo sem perguntar duas coisas.
    public var isDark: Bool { resolvedBase.isDark }

    public func selectTypography(_ preset: TypographyPreset) {
        typographyPreset = preset
        defaults.set(preset.rawValue, forKey: Self.typographyKey)
    }

    public var all: [Theme] { Theme.all }
}

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
    /// Applies a token shadow stack. CSS paints the first layer on top, and so
    /// does this: later layers are applied first so they end up underneath.
    public func shadow(_ layers: [ShadowToken]) -> some View {
        layers.reversed().reduce(AnyView(self)) { view, layer in
            AnyView(
                view.shadow(
                    color: layer.color.color,
                    radius: layer.radius,
                    x: layer.x,
                    y: layer.y
                )
            )
        }
    }
}

/// Observable holder for the user's theme choice, persisted across launches.
@MainActor
@Observable
public final class ThemeStore {
    private static let key = "okamiuni.theme"

    public private(set) var theme: Theme

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.key)
        self.theme = saved.flatMap(Theme.named) ?? .default
    }

    private let defaults: UserDefaults

    public func select(_ theme: Theme) {
        self.theme = theme
        defaults.set(theme.id, forKey: Self.key)
    }

    public var all: [Theme] { Theme.all }
}

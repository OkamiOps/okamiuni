import Foundation

/// Uma cor de caixa: nome para o menu, par claro/escuro para os temas.
///
/// O catálogo é a fonte única — o menu "Cor da caixa" e a cor automática da
/// conta nova leem daqui. As oito primeiras entradas são as que o app já
/// oferecia: contas pintadas com elas não mudam de cor.
public struct AccountTint: Sendable, Hashable, Identifiable {
    public let name: String
    public let lightHex: String
    public let darkHex: String

    public var id: String { lightHex }

    public init(name: String, lightHex: String, darkHex: String) {
        self.name = name
        self.lightHex = lightHex
        self.darkHex = darkHex
    }

    /// Ordem do menu e do ciclo automático. Hues espaçadas de propósito: com
    /// muitas caixas, vizinhos no menu não podem parecer a mesma tinta.
    public static var catalogue: [AccountTint] { [
        AccountTint(name: L10n.tr("Azul"), lightHex: "#3F6AA1", darkHex: "#8CBAF7"),
        AccountTint(name: L10n.tr("Violeta"), lightHex: "#725B9A", darkHex: "#C2A7F4"),
        AccountTint(name: L10n.tr("Verde"), lightHex: "#397852", darkHex: "#88D1A2"),
        AccountTint(name: L10n.tr("Turquesa"), lightHex: "#298084", darkHex: "#71D0D5"),
        AccountTint(name: L10n.tr("Magenta"), lightHex: "#A92769", darkHex: "#F18BBE"),
        AccountTint(name: L10n.tr("Laranja"), lightHex: "#A85424", darkHex: "#F3A46F"),
        AccountTint(name: L10n.tr("Vermelho"), lightHex: "#A23B43", darkHex: "#EF8C92"),
        AccountTint(name: L10n.tr("Grafite"), lightHex: "#59616C", darkHex: "#ABB4C0"),
        AccountTint(name: L10n.tr("Marinho"), lightHex: "#1B4F8A", darkHex: "#6A9BE0"),
        AccountTint(name: L10n.tr("Índigo"), lightHex: "#3B3F9C", darkHex: "#9A9EF0"),
        AccountTint(name: L10n.tr("Lilás"), lightHex: "#8A5AAA", darkHex: "#D0B0F0"),
        AccountTint(name: L10n.tr("Rosa"), lightHex: "#C05080", darkHex: "#F0A8C8"),
        AccountTint(name: L10n.tr("Coral"), lightHex: "#C45C48", darkHex: "#F0A090"),
        AccountTint(name: L10n.tr("Âmbar"), lightHex: "#9A7420", darkHex: "#E8C45C"),
        AccountTint(name: L10n.tr("Lima"), lightHex: "#6B8C28", darkHex: "#C4DC6C"),
        AccountTint(name: L10n.tr("Esmeralda"), lightHex: "#1E6B50", darkHex: "#5EC9A0"),
        AccountTint(name: L10n.tr("Ciano"), lightHex: "#0C7C94", darkHex: "#4EC8DC"),
        AccountTint(name: L10n.tr("Petróleo"), lightHex: "#1A5A6C", darkHex: "#5AADC0"),
        AccountTint(name: L10n.tr("Ameixa"), lightHex: "#6A3A68", darkHex: "#C888C4"),
        AccountTint(name: L10n.tr("Terracota"), lightHex: "#9A4A30", darkHex: "#E0906C"),
        AccountTint(name: L10n.tr("Hortelã"), lightHex: "#2A7A64", darkHex: "#7ED4B8"),
        AccountTint(name: L10n.tr("Cobre"), lightHex: "#8A4A24", darkHex: "#D4925C"),
        AccountTint(name: L10n.tr("Oliva"), lightHex: "#5A6B38", darkHex: "#B8C878"),
        AccountTint(name: L10n.tr("Fúcsia"), lightHex: "#B01878", darkHex: "#F068C0"),
    ] }

    public static var count: Int { catalogue.count }

    /// O par da n-ésima conta. Índice negativo também tem cor: o resto de
    /// `%` em Swift herda o sinal do dividendo, e um `-1` cru estouraria o
    /// índice em vez de dar a volta.
    public static func pair(forIndex index: Int) -> (light: String, dark: String) {
        let tint = catalogue[((index % catalogue.count) + catalogue.count) % catalogue.count]
        return (tint.lightHex, tint.darkHex)
    }
}

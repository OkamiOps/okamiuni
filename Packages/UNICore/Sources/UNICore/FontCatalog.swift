import Foundation

/// As famílias que o menu de fonte do composer oferece.
///
/// Duas listas, não uma: **as seis do protótipo** (`FONT_VALUES`, linha 1774 do
/// `.dc.html`) continuam no topo, porque são a escolha rápida que o design
/// desenhou; abaixo de um separador vêm as **instaladas na máquina**, porque
/// limitar a seis era o que o dono do projeto relatou ("fontes também limitada,
/// o certo era ter as fontes que o sistema tem").
///
/// Somar as duas, e não trocar uma pela outra: uma lista alfabética de 300
/// entradas esconde as seis do design no meio das outras, e escolher a fonte do
/// design deixaria de ser um gesto.
///
/// Isto mora em `UNICore`, fora de qualquer `View`, pelo motivo de sempre —
/// `View` é `@MainActor` implícito no Swift 6 e lógica pura pendurada nela trapa
/// em teste nonisolated. Quem lê o `NSFontManager` é a `View`; quem decide o
/// que entra na lista, a peneira e a ordem é isto aqui, que o teste chama
/// direto com uma lista de mentira.
public enum FontCatalog {

    /// Uma entrada do menu. `value` é o que vai para `BodyStyle.family`;
    /// `label` é o que a pessoa lê.
    ///
    /// Os dois divergem só nas do protótipo: `-apple-system` é um token do CSS
    /// e ninguém reconheceria por esse nome — o menu escreve "SF Pro". Numa
    /// família instalada os dois são o nome da família.
    public struct Family: Sendable, Hashable, Identifiable {
        public var id: String { value }
        public let value: String
        public let label: String

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    /// Protótipo: `FONT_VALUES`, com os rótulos que o `<select>` mostra.
    public static let design: [Family] = [
        Family(value: "Newsreader", label: "Newsreader"),
        Family(value: "-apple-system", label: "SF Pro"),
        Family(value: "Space Grotesk", label: "Space Grotesk"),
        Family(value: "Georgia", label: "Georgia"),
        Family(value: "Helvetica", label: "Helvetica"),
        Family(value: "JetBrains Mono", label: "JetBrains Mono"),
    ]

    /// Protótipo: as sete opções de `SIZE_MAP`.
    public static let sizes: [Double] = [11, 13, 15, 17, 20, 24, 32]

    /// As famílias instaladas que o menu mostra abaixo do separador.
    ///
    /// Três regras, e cada uma existe por um motivo que se vê na tela:
    ///
    /// 1. **Fora as ocultas.** O AppKit devolve famílias de sistema com ponto
    ///    na frente (`.AppleSystemUIFont`, `.SF NS`). Elas não são para escolha
    ///    humana e sujariam o topo da lista, que é ordenada por nome.
    /// 2. **Fora as repetidas.** Georgia e Helvetica estão nas seis do design
    ///    **e** instaladas em qualquer Mac. Aparecer duas vezes faria a segunda
    ///    parecer uma fonte diferente da primeira.
    /// 3. **Ordem alfabética de gente**, com `localizedStandardCompare`: é a
    ///    que põe "Arial" antes de "Avenir" e não separa maiúscula de
    ///    minúscula. A ordem em que o `NSFontManager` devolve não é ordem
    ///    nenhuma que sirva para procurar com o olho.
    public static func installed(from families: [String]) -> [Family] {
        let taken = Set(design.flatMap { [$0.value.lowercased(), $0.label.lowercased()] })
        return families
            .filter { !$0.hasPrefix(".") }
            .filter { !taken.contains($0.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Family(value: $0, label: $0) }
    }

    /// O que o controle fechado escreve para a família escolhida.
    ///
    /// Uma família instalada é o próprio nome; uma do design é o rótulo dela.
    /// Sem isto o controle mostraria `-apple-system` depois de a pessoa
    /// escolher "SF Pro" no menu.
    public static func label(for value: String) -> String {
        design.first { $0.value == value }?.label ?? value
    }
}

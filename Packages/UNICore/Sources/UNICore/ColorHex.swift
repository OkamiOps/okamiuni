import Foundation

/// A ponte entre uma cor escolhida livremente e o `#RRGGBB` que
/// `BodyStyle.colorHex` guarda.
///
/// Existe porque o seletor de cor deixou de ser uma paleta fechada: as seis do
/// protótipo continuam como atalho, e o "Outra cor…" abre o `NSColorPanel`, que
/// devolve componentes, não texto. O modelo do corpo é `Codable` e atravessa a
/// fronteira do rascunho — guardar uma `NSColor` ali seria trocar um texto
/// estável por um objeto de AppKit.
///
/// Pura de propósito, e em `UNICore`: quem chama isto é a `View` do seletor,
/// mas a conversão precisa ser chamável de teste nonisolated.
public enum ColorHex {

    /// `#RRGGBB` a partir de componentes sRGB de 0 a 1.
    ///
    /// **Sem canal alfa.** `BodyStyle.colorHex` documenta que nunca é
    /// `transparent`: texto invisível não é formatação. Uma cor meio
    /// transparente escolhida na roda entra pela cor cheia dela, que é o que a
    /// pessoa vê na amostra.
    ///
    /// Fora da faixa entra grampeado em vez de estourar: o `NSColorPanel` pode
    /// devolver componentes fora de 0…1 quando a cor vem de um espaço mais
    /// largo que o sRGB — um vermelho de Display P3 chega como 1,09.
    public static func string(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int {
            guard value.isFinite else { return 0 }
            return Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// Se este texto é uma cor livre — quer dizer, não é nenhuma das do
    /// protótipo nem o `transparent` que significa "sem realce".
    ///
    /// A paleta usa isto para acender a amostra "Outra cor…" quando a escolha
    /// atual não é nenhuma das seis: sem isso o painel abriria sem nada
    /// marcado e a pessoa não saberia qual cor está aplicada.
    public static func isCustom(_ hex: String, among palette: [String]) -> Bool {
        guard hex != BodyStyle.noHighlight else { return false }
        return !palette.contains { $0.caseInsensitiveCompare(hex) == .orderedSame }
    }
}

import Foundation

/// Como o nome do provedor cabe na trilha recolhida.
///
/// A trilha tem `PaneLayout.railWidth` (62pt) e a marca da conta ocupa 40 deles
/// — "HOSTINGER" a 10pt mono mede bem mais que isso. O design já resolve assim:
/// `mark: ACC[k].host.slice(0, 3)`.
///
/// **Encurtar é renderização, não modelo.** `Account.host` continua sendo o
/// nome inteiro; ninguém guarda uma segunda versão curta dele. É a mesma
/// decisão já registrada em `docs/decisoes-de-engenharia.md` para os títulos
/// da grade da semana: coluna estreita encurta ao desenhar.
///
/// Fora de qualquer `View` de propósito — `View` é `@MainActor` implícito no
/// Swift 6 e um `static` lá dentro trapa em teste nonisolated.
public enum HostMark {

    /// Quantas letras a marca da trilha mostra. Design: `slice(0, 3)`.
    public static let railLetters = 3

    /// A marca da conta na trilha recolhida: "hostinger" → "HOS".
    ///
    /// Corta por contagem de `Character`, não de byte nem de `unicodeScalar`,
    /// para que um host acentuado não perca o acento no corte.
    public static func rail(_ host: String) -> String {
        String(host.prefix(railLetters)).uppercased()
    }
}

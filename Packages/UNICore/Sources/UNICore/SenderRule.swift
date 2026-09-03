import Foundation

/// "Nunca é prioridade" — a regra que a pessoa ensinou sobre um remetente.
///
/// Por **endereço exato**, e não por domínio: aprender que a newsletter do
/// `news@zoho.com` não é prioridade não pode calar o vendedor da Zoho que
/// responde de `carol@zoho.com`. A spec exige que a regra seja revogável em
/// Configurações e que apareça em "Tirei da lista" — as duas coisas só são
/// possíveis se ela for um dado, e não um filtro escondido no ranking.
public struct SenderRule: Sendable, Hashable, Codable {
    public let address: String
    public let neverPriority: Bool
    public let createdAt: Date

    public init(address: String, neverPriority: Bool = true, createdAt: Date) {
        self.address = address
        self.neverPriority = neverPriority
        self.createdAt = createdAt
    }

    /// O endereço como se compara: sem espaço em volta, em minúsculas. Duas
    /// grafias do mesmo endereço são o mesmo remetente.
    public var normalizedAddress: String {
        SenderRule.normalize(address)
    }

    public static func normalize(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// O texto que o rodapé "Tirei da lista" escreve ao lado do assunto.
    public static let removalReason = "regra sua: nunca é prioridade"

    /// Os endereços que estas regras calam.
    public static func silencedAddresses(_ rules: [SenderRule]) -> Set<String> {
        Set(rules.filter(\.neverPriority).map(\.normalizedAddress))
    }

    /// Alguma regra cala este remetente.
    public static func silences(_ rules: [SenderRule], address: String) -> Bool {
        silencedAddresses(rules).contains(normalize(address))
    }
}

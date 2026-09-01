import Foundation

/// Um endereço extra pelo qual a conta pode sair.
///
/// O endereço principal continua em `Account.address`. Isto é o que a pessoa
/// configura à mão — ou o que o Gmail já tem em "Enviar como" — para o
/// composer oferecer mais de um "De" sem fingir que são contas diferentes.
public struct SendAlias: Sendable, Hashable, Codable, Identifiable {
    public var id: String { address.lowercased() }
    public let address: String
    public let displayName: String
    public let isDefault: Bool
    public let origin: Origin

    public enum Origin: String, Sendable, Codable, Hashable {
        case manual
        case gmail
    }

    public init(
        address: String,
        displayName: String,
        isDefault: Bool = false,
        origin: Origin = .manual
    ) {
        self.address = address
        self.displayName = displayName
        self.isDefault = isDefault
        self.origin = origin
    }

    public func withDefault(_ isDefault: Bool) -> SendAlias {
        SendAlias(
            address: address, displayName: displayName,
            isDefault: isDefault, origin: origin
        )
    }

    public func withDisplayName(_ displayName: String) -> SendAlias {
        SendAlias(
            address: address, displayName: displayName,
            isDefault: isDefault, origin: origin
        )
    }

    /// Endereço que dá para usar como From. Sem `@` ou com espaço, não.
    public static func parse(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@") else { return nil }
        let local = trimmed[..<at]
        let domain = trimmed[trimmed.index(after: at)...]
        guard !local.isEmpty, domain.contains("."), !trimmed.contains(where: \.isWhitespace)
        else { return nil }
        return trimmed
    }

    /// Tira o principal, endereços inválidos e duplicatas. No máximo um
    /// `isDefault`.
    public static func normalized(
        _ aliases: [SendAlias], excluding primary: String
    ) -> [SendAlias] {
        let primaryKey = primary.lowercased()
        var seen: Set<String> = [primaryKey]
        var cleaned: [SendAlias] = []
        for alias in aliases {
            guard let address = parse(alias.address) else { continue }
            let key = address.lowercased()
            guard seen.insert(key).inserted else { continue }
            cleaned.append(SendAlias(
                address: address,
                displayName: alias.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                isDefault: alias.isDefault,
                origin: alias.origin
            ))
        }
        if let firstDefault = cleaned.firstIndex(where: \.isDefault) {
            cleaned = cleaned.enumerated().map { index, alias in
                alias.withDefault(index == firstDefault)
            }
        }
        return cleaned
    }

    /// Gmail traz os "Enviar como". Os manuais que não colidem ficam.
    public static func merging(
        gmail: [(email: String, displayName: String, isPrimary: Bool, isDefault: Bool)],
        existing: [SendAlias],
        primary: String
    ) -> [SendAlias] {
        let primaryKey = primary.lowercased()
        var fromGmail: [SendAlias] = []
        var defaultAddress: String?
        for item in gmail {
            if item.isDefault { defaultAddress = item.email }
            if item.isPrimary { continue }
            guard let address = parse(item.email) else { continue }
            guard address.lowercased() != primaryKey else { continue }
            fromGmail.append(SendAlias(
                address: address,
                displayName: item.displayName,
                isDefault: false,
                origin: .gmail
            ))
        }
        let gmailKeys = Set(fromGmail.map { $0.address.lowercased() })
        let manuals = existing.filter {
            $0.origin == .manual && !gmailKeys.contains($0.address.lowercased())
        }
        var combined = fromGmail + manuals
        if let defaultAddress,
           defaultAddress.lowercased() != primaryKey,
           let index = combined.firstIndex(where: {
               $0.address.lowercased() == defaultAddress.lowercased()
           }) {
            combined = combined.enumerated().map { i, alias in
                alias.withDefault(i == index)
            }
        }
        return normalized(combined, excluding: primary)
    }
}

/// Um remetente concreto: a conta principal ou um alias dela.
public struct SendIdentity: Sendable, Hashable, Identifiable {
    public var id: String { "\(accountID)\u{1e}\(address.lowercased())" }
    public let accountID: String
    public let address: String
    public let displayName: String
    public let isPrimary: Bool

    public init(accountID: String, address: String, displayName: String, isPrimary: Bool) {
        self.accountID = accountID
        self.address = address
        self.displayName = displayName
        self.isPrimary = isPrimary
    }

    public var pickerValue: String { id }

    public var pickerLabel: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return address }
        return "\(name) · \(address)"
    }

    public static func decodePickerValue(_ raw: String) -> (accountID: String, address: String)? {
        let parts = raw.split(separator: "\u{1e}", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
}

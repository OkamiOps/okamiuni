import Foundation

public struct Contact: Sendable, Hashable, Identifiable {
    public var id: String { address.lowercased() }
    public let name: String
    public let address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }

    /// Duas letras para o avatar. Nomes de três ou mais palavras usam a
    /// primeira e a última — "Ana Beatriz Silva" vira "AS", não "AB".
    public var initials: String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        switch words.count {
        case 0:
            return address.first.map { String($0).uppercased() } ?? "?"
        case 1:
            return String(words[0].prefix(1)).uppercased()
        default:
            let first = words[0].prefix(1)
            let last = words[words.count - 1].prefix(1)
            return (first + last).uppercased()
        }
    }

    /// Como o protótipo escreve: "Marina Duarte · marina@clientepremium.com"
    public var display: String {
        name.isEmpty ? address : "\(name) · \(address)"
    }
}

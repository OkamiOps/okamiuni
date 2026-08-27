import Foundation

/// Um contato do catálogo, com o que o menu de sugestões mostra além do nome.
/// Protótipo: `CONTACTS = [{ name, email, freq, org }]`.
public struct DirectoryContact: Sendable, Hashable, Identifiable {
    public var id: String { address.lowercased() }
    public let name: String
    public let address: String
    /// "Cliente Premium", "Interno", "TransRota"… aparece à direita da linha.
    public let org: String
    /// Quantas vezes o usuário já escreveu para esta pessoa. Ordena "Mais usados".
    public let frequency: Int

    public init(name: String, address: String, org: String, frequency: Int) {
        self.name = name
        self.address = address
        self.org = org
        self.frequency = frequency
    }

    public var contact: Contact { Contact(name: name, address: address) }
    public var initials: String { contact.initials }

    /// Um endereço digitado à mão, que não está no catálogo. Protótipo:
    /// `add(hit || { name: raw, email: raw, freq: 0, org: '' })`.
    public static func typed(_ raw: String) -> DirectoryContact {
        DirectoryContact(name: raw, address: raw, org: "", frequency: 0)
    }
}

/// O catálogo por trás dos campos Para/Cc/Cco. Puro de propósito: um `View` do
/// SwiftUI é `@MainActor` e esta aritmética precisa ser chamável de teste.
public enum ContactDirectory {
    /// Protótipo: `.slice(0, 5)`.
    public static let suggestionLimit = 5

    /// Protótipo: `label: q ? 'Contatos' : 'Mais usados'`.
    public static func menuLabel(query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? "Mais usados" : "Contatos"
    }

    /// As até cinco linhas do menu.
    ///
    /// Sem busca, os mais escritos primeiro. Com busca, o trecho é procurado em
    /// nome, endereço e organização, e a ordem do catálogo é preservada — é o
    /// que o protótipo faz (`pool.filter(...)`, sem reordenar).
    /// Quem já virou etiqueta no campo sai do menu.
    public static func suggestions(
        matching query: String,
        excluding chosen: [Contact],
        in pool: [DirectoryContact]
    ) -> [DirectoryContact] {
        let taken = Set(chosen.map { $0.address.lowercased() })
        let available = pool.filter { !taken.contains($0.address.lowercased()) }
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()

        let matched: [DirectoryContact]
        if term.isEmpty {
            matched = available.sorted { $0.frequency > $1.frequency }
        } else {
            matched = available.filter {
                "\($0.name) \($0.address) \($0.org)".lowercased().contains(term)
            }
        }
        return Array(matched.prefix(suggestionLimit))
    }

    /// O que "; " ou ", " no fim do texto vira: o primeiro contato que casa com
    /// o que foi digitado, ou o próprio texto como endereço solto.
    /// Protótipo: `CONTACTS.find(c => (c.name + ' ' + c.email).includes(raw))`.
    public static func resolve(typed raw: String, in pool: [DirectoryContact]) -> DirectoryContact? {
        let term = raw.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return nil }
        let needle = term.lowercased()
        let hit = pool.first { "\($0.name) \($0.address)".lowercased().contains(needle) }
        return hit ?? .typed(term)
    }
}

/// Contagem e carimbo do rascunho — os dois rótulos em mono das janelas 03 e 06.
public enum DraftMeta {
    /// Palavras separadas por espaço em branco.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Protótipo: `words ? words + (words === 1 ? ' palavra' : ' palavras') : 'rascunho vazio'`.
    public static func countLabel(_ text: String) -> String {
        let words = wordCount(text)
        guard words > 0 else { return "rascunho vazio" }
        return "\(words) \(words == 1 ? "palavra" : "palavras")"
    }

    /// Protótipo: `saved ? 'rascunho salvo ' + saved : 'não salvo'`.
    public static func savedLabel(_ stamp: String?) -> String {
        guard let stamp, !stamp.isEmpty else { return "não salvo" }
        return "rascunho salvo \(stamp)"
    }
}

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
    /// O catálogo **real**: para quem a pessoa já escreveu. Só destinatários e
    /// cópias de mensagens em Enviadas entram; receber newsletter, recibo ou
    /// campanha de marketing não cria contato e não polui "Mais usados".
    /// Pura e testável sem banco — `Message` já chega com
    /// `bucket`/`to`/`cc`/`receivedAt` decodificados, venha ela do banco
    /// (`DatabaseContactDirectory`, no `UNISync`) ou das fixtures.
    ///
    /// Deduplicado por endereço, sem diferenciar caixa — é `Contact.id` quem
    /// decide isso. Relevância simples: quem apareceu mais vezes primeiro;
    /// empate desfeito por quem apareceu mais recentemente; empate nisso, por
    /// nome e depois endereço, para a lista não dançar entre duas chamadas
    /// com a mesma entrada.
    public static func build(
        fromMessages messages: [Message], excluding ownAddresses: Set<String> = []
    ) -> [DirectoryContact] {
        var order: [String] = []
        var seen: Set<String> = []
        var address: [String: String] = [:]
        var name: [String: String] = [:]
        var frequency: [String: Int] = [:]
        var latest: [String: Date] = [:]
        var excluded = Set(ownAddresses.map { $0.lowercased() })
        excluded.formUnion(
            messages.lazy.filter { $0.bucket == .sent }.map { $0.from.id }
        )

        func touch(_ contact: Contact, at date: Date) {
            guard !contact.address.isEmpty, !excluded.contains(contact.id) else { return }
            let key = contact.id
            if seen.insert(key).inserted {
                order.append(key)
                address[key] = contact.address
            }
            frequency[key, default: 0] += 1
            if let atual = latest[key] {
                if date > atual { latest[key] = date }
            } else {
                latest[key] = date
            }
            if (name[key] ?? "").isEmpty, !contact.name.isEmpty {
                name[key] = contact.name
            }
        }

        for message in messages where message.bucket == .sent {
            // Uma pessoa em To e Cc no mesmo email conta como uma interação,
            // não duas. Entre mensagens diferentes a frequência continua
            // subindo, que é exatamente o significado de "Mais usados".
            var touchedInMessage: Set<String> = []
            for recipient in message.to + message.cc
            where touchedInMessage.insert(recipient.id).inserted {
                touch(recipient, at: message.receivedAt)
            }
        }

        return order.map { key in
            DirectoryContact(
                name: name[key] ?? "", address: address[key] ?? key,
                org: "", frequency: frequency[key] ?? 0
            )
        }.sorted { left, right in
            if left.frequency != right.frequency { return left.frequency > right.frequency }
            let dataEsquerda = latest[left.id] ?? .distantPast
            let dataDireita = latest[right.id] ?? .distantPast
            if dataEsquerda != dataDireita { return dataEsquerda > dataDireita }
            if left.name != right.name { return left.name < right.name }
            return left.address < right.address
        }
    }

    /// Protótipo: `.slice(0, 5)`.
    public static let suggestionLimit = 5

    /// Protótipo: `label: q ? 'Contatos' : 'Mais usados'`.
    public static func menuLabel(query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? "Mais usados" : "Contatos"
    }

    /// Dobra caixa **e** acento: "marina" acha "Marina", "márina" também, e
    /// "Cláudia" é achada digitando "claudia".
    ///
    /// `locale: nil` de propósito — dobrar contra `Locale.current` faria a
    /// busca mudar de resultado conforme a máquina, que é a mesma classe de
    /// defeito do fuso fixado numa fixture.
    ///
    /// Era exclusividade da máquina de sugestões da faixa de resposta; a do
    /// campo de destinatário não dobrava, e as duas conviviam na mesma janela
    /// discordando. A dobra é o comportamento certo, e agora é o único.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// O contato casa com o trecho digitado?
    ///
    /// Procura em **nome, endereço e organização**: digitar "Interno" tem de
    /// achar quem é do time interno, que é a coluna que o menu mostra à direita
    /// da linha. Trecho vazio casa com todo mundo — é o estado "Mais usados".
    ///
    /// **Esta é a única definição.** `QuickReply.matches` delega para cá.
    public static func matches(_ contact: DirectoryContact, query: String) -> Bool {
        let needle = fold(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return true }
        return fold("\(contact.name) \(contact.address) \(contact.org)").contains(needle)
    }

    /// As até cinco linhas do menu.
    ///
    /// Sem busca, os mais escritos primeiro. Com busca, a ordem do catálogo é
    /// preservada — é o que o protótipo faz (`pool.filter(...)`, sem reordenar).
    /// Quem já virou etiqueta no campo sai do menu.
    public static func suggestions(
        matching query: String,
        excluding chosen: [Contact],
        in pool: [DirectoryContact]
    ) -> [DirectoryContact] {
        let taken = Set(chosen.map { $0.address.lowercased() })
        let available = pool.filter { !taken.contains($0.address.lowercased()) }
        let term = query.trimmingCharacters(in: .whitespaces)

        let matched: [DirectoryContact]
        if term.isEmpty {
            matched = available.sorted { $0.frequency > $1.frequency }
        } else {
            matched = available.filter { matches($0, query: term) }
        }
        return Array(matched.prefix(suggestionLimit))
    }

    /// O que "; " ou ", " no fim do texto vira: o primeiro contato que casa com
    /// o que foi digitado, ou o próprio texto como endereço solto — um
    /// destinatário de fora do catálogo tem de poder entrar.
    /// Protótipo: `CONTACTS.find(c => (c.name + ' ' + c.email).includes(raw))`.
    public static func resolve(typed raw: String, in pool: [DirectoryContact]) -> DirectoryContact? {
        let term = raw.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return nil }
        return pool.first { matches($0, query: term) } ?? .typed(term)
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

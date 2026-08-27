import Foundation

/// O rascunho de uma resposta rápida, escrito na faixa embutida no leitor.
///
/// Existe para atravessar duas fronteiras sem se perder: a faixa que fecha e
/// reabre, e o "⤢" que promove a resposta para a janela cheia. Por isso ele
/// mora no `MailStore` (`replyDraft(for:)` / `setReplyDraft(_:for:)`) e não em
/// `@State` de uma `View` — estado de `View` morre quando a `View` sai da tela,
/// e perder o que a pessoa escreveu é pior do que não ter o botão.
public struct ReplyDraft: Sendable, Hashable {
    /// Quem recebe. Começa com o remetente da mensagem respondida.
    public var to: [Contact]
    /// O corpo, texto puro. Marco 1 não tem rich text no leitor.
    public var text: String
    /// Quando o rascunho foi guardado pela última vez. `nil` = nunca guardado
    /// explicitamente (só está em memória enquanto se digita).
    public var savedAt: Date?

    public init(to: [Contact] = [], text: String = "", savedAt: Date? = nil) {
        self.to = to
        self.text = text
        self.savedAt = savedAt
    }

    /// Sem destinatário e sem texto — nada que valha a pena guardar.
    public var isEmpty: Bool {
        to.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Há de fato algo escrito. Um rascunho com só o destinatário semeado não
    /// conta: ninguém escreveu nada ali.
    public var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A aritmética da faixa de resposta rápida: de onde saem as sugestões, o que
/// casa com o que se digita, e o que entra e sai do campo de destinatário.
///
/// Puro de propósito, e fora de qualquer `View`: no Swift 6 uma `View` é
/// `@MainActor` implícito e um `static` dentro dela trapa em runtime quando um
/// teste nonisolated o chama. É a mesma razão de `AgendaSummary` e `PaneLayout`
/// morarem aqui.
public enum QuickReply {
    /// Protótipo: o menu da faixa mostra no máximo cinco linhas.
    public static let suggestionLimit = 5

    /// Dobra caixa **e** acento: "claudia" acha "Cláudia", "MARINA" acha
    /// "Marina". `locale: nil` de propósito — dobrar contra `Locale.current`
    /// faria a busca mudar de resultado conforme a máquina, que é a mesma
    /// classe de defeito do fuso fixado na fixture de "hoje".
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// O contato casa com o trecho digitado? Procura em **nome e endereço**,
    /// os dois campos que o protótipo mostra na linha do menu. Trecho vazio
    /// casa com todo mundo — é o estado "Mais usados".
    public static func matches(_ contact: DirectoryContact, query: String) -> Bool {
        let needle = fold(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return true }
        return fold(contact.name).contains(needle) || fold(contact.address).contains(needle)
    }

    /// Os contatos que o app conhece, montados a partir do que existe.
    ///
    /// A base são os **remetentes das mensagens** — qualquer nome, qualquer
    /// domínio, qualquer provedor. Nada aqui olha para conta nem para host: uma
    /// lista fixa de domínios seria exatamente o que este projeto não faz.
    /// `catalog` é o caderno de endereços que o app já tenha (no Marco 1, o do
    /// protótipo); quem aparece nos dois soma as duas frequências e fica com o
    /// nome e a organização do caderno, que são os mais completos.
    ///
    /// Ordem: mais escritos primeiro, e empate resolvido por nome e endereço
    /// para a lista não dançar entre duas execuções.
    public static func directory(
        messages: [Message],
        catalog: [DirectoryContact] = []
    ) -> [DirectoryContact] {
        var order: [String] = []
        var byKey: [String: DirectoryContact] = [:]

        func merge(_ entry: DirectoryContact, addingFrequency extra: Int) {
            let key = entry.id
            if let existing = byKey[key] {
                byKey[key] = DirectoryContact(
                    name: entry.name.isEmpty ? existing.name : entry.name,
                    address: existing.address,
                    org: entry.org.isEmpty ? existing.org : entry.org,
                    frequency: existing.frequency + extra
                )
            } else {
                order.append(key)
                byKey[key] = DirectoryContact(
                    name: entry.name, address: entry.address,
                    org: entry.org, frequency: extra
                )
            }
        }

        for message in messages where !message.from.address.isEmpty {
            merge(
                DirectoryContact(
                    name: message.from.name, address: message.from.address,
                    org: "", frequency: 0
                ),
                addingFrequency: 1
            )
        }
        for entry in catalog where !entry.address.isEmpty {
            merge(entry, addingFrequency: entry.frequency)
        }

        return order.compactMap { byKey[$0] }.sorted { left, right in
            if left.frequency != right.frequency { return left.frequency > right.frequency }
            if left.name != right.name { return left.name < right.name }
            return left.address < right.address
        }
    }

    /// As até cinco linhas do menu, na ordem do catálogo (que já vem por
    /// frequência). Quem já virou etiqueta sai da lista.
    public static func suggestions(
        matching query: String,
        excluding chosen: [Contact],
        in pool: [DirectoryContact]
    ) -> [DirectoryContact] {
        let taken = Set(chosen.map(\.id))
        let hits = pool.filter { !taken.contains($0.id) && matches($0, query: query) }
        return Array(hits.prefix(suggestionLimit))
    }

    /// Protótipo: `label: q ? 'Contatos' : 'Mais usados'`.
    public static func menuLabel(query: String) -> String {
        ContactDirectory.menuLabel(query: query)
    }

    /// O que "; " ou ", " no fim do texto vira: o primeiro contato que casa,
    /// ou o próprio texto como endereço solto — um destinatário de fora do
    /// catálogo tem de poder entrar.
    public static func resolve(typed raw: String, in pool: [DirectoryContact]) -> DirectoryContact? {
        let term = raw.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return nil }
        return pool.first { matches($0, query: term) } ?? .typed(term)
    }

    /// Acrescenta sem duplicar. Devolve a lista nova em vez de mutar, para a
    /// regra ser testável fora de qualquer `View`.
    public static func adding(_ contact: Contact, to chips: [Contact]) -> [Contact] {
        guard !chips.contains(where: { $0.id == contact.id }) else { return chips }
        return chips + [contact]
    }

    /// Tira a etiqueta pelo endereço, sem depender do nome.
    public static func removing(_ contact: Contact, from chips: [Contact]) -> [Contact] {
        chips.filter { $0.id != contact.id }
    }
}

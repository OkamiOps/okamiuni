import Foundation
import UNICore

/// Enviar também precisa resolver o texto que ainda não virou etiqueta.
/// Uma entrada inválida bloqueia a mensagem inteira; nunca some da lista.
enum ComposerRecipients {
    static func resolve(
        _ contacts: [Contact], typed: String, pool: [DirectoryContact]
    ) -> [Contact]? {
        guard contacts.allSatisfy({ EmailAddress.normalized($0.address) != nil }) else { return nil }
        var term = typed.trimmingCharacters(in: .whitespaces)
        if term.hasSuffix(";") || term.hasSuffix(",") { term.removeLast() }
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { return contacts }
        guard let resolved = ContactDirectory.resolve(typed: term, in: pool) else { return nil }
        guard !contacts.contains(where: { $0.id == resolved.contact.id }) else { return contacts }
        return contacts + [resolved.contact]
    }
}

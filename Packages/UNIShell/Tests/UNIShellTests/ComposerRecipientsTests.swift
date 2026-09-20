import Testing
import UNICore
@testable import UNIShell

@Suite("O envio inclui destinatários ainda digitados")
struct ComposerRecipientsTests {
    @Test("Email novo é incluído sem exigir Enter ou ponto e vírgula")
    func typedRecipient() throws {
        let contacts = try #require(ComposerRecipients.resolve([], typed: "novo@example.com", pool: []))
        #expect(contacts.map(\.address) == ["novo@example.com"])
    }

    @Test("Entrada inválida não desaparece quando já existe um destinatário válido")
    func invalidRecipientStopsSend() {
        let contacts = [Contact(name: "Ana", address: "ana@example.com")]
        #expect(ComposerRecipients.resolve(contacts, typed: "invalido", pool: []) == nil)
        #expect(ComposerRecipients.resolve(
            [Contact(name: "Antigo", address: "ana@example.com\")(\"Outro")], typed: "", pool: []
        ) == nil)
    }

    @Test("Destinatário já confirmado não é duplicado ao enviar")
    func existingRecipient() {
        let contacts = [Contact(name: "Ana", address: "ana@example.com")]
        #expect(ComposerRecipients.resolve(contacts, typed: "ana@example.com;", pool: []) == contacts)
        #expect(ComposerRecipients.resolve(contacts, typed: "", pool: []) == contacts)
    }
}

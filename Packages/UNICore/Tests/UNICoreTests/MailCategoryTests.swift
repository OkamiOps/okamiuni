import Foundation
import Testing
@testable import UNICore

@Suite("Categorias de intenção de e-mail")
struct MailCategoryTests {
    @Test("A saída do modelo aceita somente o enum fechado")
    func validatesModelValue() {
        #expect(MailCategory(validatedModelValue: " PROMOTIONS ") == .promotions)
        #expect(MailCategory(validatedModelValue: "not-a-category") == nil)
        #expect(MailCategory(validatedModelValue: nil) == nil)
    }

    @Test("Resolver identifica newsletter, transação, social e atualização")
    func resolvesConservativeAliases() {
        #expect(
            MailCategory.resolve(
                message: message(subject: "Novas ofertas", sender: "Loja"),
                folderNames: ["Newsletter"]
            ) == .promotions
        )
        #expect(
            MailCategory.resolve(
                message: message(subject: "Seu pedido, recibo e desconto", sender: "Loja"),
                folderNames: []
            ) == .transactions
        )
        #expect(
            MailCategory.resolve(
                message: message(subject: "Mensagem da comunidade", sender: "Discord"),
                folderNames: []
            ) == .social
        )
        #expect(
            MailCategory.resolve(
                message: message(subject: "Atualização de status", sender: "Sistema"),
                folderNames: []
            ) == .updates
        )
    }

    @Test("Sem sinal explícito, conversa fica em Principal")
    func defaultsToPrimary() {
        #expect(
            MailCategory.resolve(
                message: message(subject: "Falamos amanhã", sender: "Marina"),
                folderNames: []
            ) == .primary
        )
    }

    @Test("Pasta Newsletter sozinha não reclassifica conversa de cliente")
    func newsletterFolderAloneDoesNotOverrideClientConversation() {
        #expect(
            MailCategory.resolve(
                message: message(subject: "Revisão do contrato", sender: "Marina Cliente"),
                folderNames: ["Newsletter"]
            ) == .primary
        )
    }

    @Test("Categoria já persistida vence a heurística")
    func persistedCategoryWins() {
        #expect(
            MailCategory.resolve(
                message: message(
                    subject: "Sua fatura chegou",
                    sender: "Loja",
                    category: .social
                ),
                folderNames: ["Newsletter"]
            ) == .social
        )
    }

    private func message(
        subject: String,
        sender: String,
        category: MailCategory? = nil
    ) -> Message {
        Message(
            id: UUID().uuidString,
            accountID: "account",
            from: Contact(name: sender, address: "sender@example.com"),
            receivedAt: Date(timeIntervalSince1970: 0),
            subject: subject,
            snippet: subject,
            body: [],
            tags: [],
            bucket: .today,
            isRead: true,
            summary: nil,
            detectedEvent: nil,
            category: category
        )
    }
}

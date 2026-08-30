import Foundation
import Testing
import UNICore
@testable import UNISync

@Suite("Anexos recebidos: cache local e limites")
struct DatabaseAttachmentFetcherTests {
    private let account = Account(
        id: "a", address: "eu@example.com", displayName: "Eu",
        provider: .imap, host: "example.com",
        tintLightHex: "#315d8a", tintDarkHex: "#7ba8d9"
    )

    private func seed(_ database: SyncDatabase, attachment: MessageAttachmentRecord) async throws {
        try await database.pool.write { db in
            try AccountRecord(account, createdAt: .now).save(db)
            try FolderRecord(
                id: "a/INBOX", accountID: account.id,
                serverName: "INBOX", role: .inbox, displayName: "Entrada"
            ).save(db)
            try MessageRecord(
                Message(
                    id: "m", accountID: account.id,
                    from: Contact(name: "Ana", address: "ana@example.com"),
                    receivedAt: .now, subject: "Arquivo", snippet: "Arquivo",
                    body: [], tags: [], bucket: .today, isRead: false,
                    summary: nil, detectedEvent: nil
                ), folderID: "a/INBOX"
            ).save(db)
            try attachment.insert(db)
        }
    }

    @Test("bytes já cacheados retornam sem rede")
    func returnsCachedAttachment() async throws {
        let database = try SyncDatabase.temporary()
        let data = Data("conteúdo".utf8)
        let record = MessageAttachmentRecord(
            id: "m:imap:0", messageID: "m", filename: "../contrato.pdf",
            mimeType: "application/pdf", byteCount: data.count, data: data
        )
        try await seed(database, attachment: record)

        let port = DatabaseAttachmentFetcher(database: database, auth: nil, session: .shared)
        let fetched = try await port.fetchAttachment(
            accountID: account.id, messageID: "m", attachmentID: record.id
        )
        #expect(fetched.attachment.filename == "contrato.pdf")
        #expect(fetched.data == data)
    }

    /// Uma checagem de mutação: se o teto for movido para depois da busca,
    /// este registro sem bytes tenta uma rota de servidor inexistente em vez de
    /// dar a falha segura e explícita.
    @Test("metadado acima do teto falha antes de qualquer recuperação")
    func rejectsOversizedMetadata() async throws {
        let database = try SyncDatabase.temporary()
        let record = MessageAttachmentRecord(
            id: "m:imap:grande", messageID: "m", filename: "grande.zip",
            mimeType: "application/zip", byteCount: OutgoingAttachment.maximumByteCount + 1
        )
        try await seed(database, attachment: record)

        let port = DatabaseAttachmentFetcher(database: database, auth: nil, session: .shared)
        await #expect(throws: AttachmentError.fileTooLarge(limit: OutgoingAttachment.maximumByteCount)) {
            _ = try await port.fetchAttachment(
                accountID: self.account.id, messageID: "m", attachmentID: record.id
            )
        }
    }
}

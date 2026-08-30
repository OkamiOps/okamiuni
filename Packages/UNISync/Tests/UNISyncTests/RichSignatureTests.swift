import Foundation
import GRDB
import NIOCore
import NIOPosix
import Testing
import UNICore
@testable import UNISync

@Suite("Assinatura rica persistida e enviada")
struct RichSignatureTests {
    private func resource() throws -> InlineSignatureResource {
        try InlineSignatureResource(
            contentID: "logo@inline.local", mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47])
        )
    }

    private func signature() throws -> EmailSignature {
        let logo = try resource()
        return try EmailSignature(
            plainText: "Marcos\nOkamiUNI",
            html: "<p><strong>Marcos</strong></p><img src=\"cid:logo@inline.local\">",
            inlineResources: [logo]
        )
    }

    private func account(signature: EmailSignature) -> Account {
        Account(
            id: "conta-rica", address: "marcos@example.com", displayName: "Marcos",
            provider: .imap, host: "example", tintLightHex: "#111111", tintDarkHex: "#eeeeee",
            emailSignature: signature
        )
    }

    @Test("JSON rico é aditivo e a coluna antiga continua fallback")
    func persistenceAndLegacyFallback() async throws {
        let db = try SyncDatabase.temporary()
        let rich = try signature()
        let current = account(signature: rich)
        try await db.pool.write { connection in
            try AccountRecord(current, createdAt: Date(timeIntervalSince1970: 1)).insert(connection)
        }
        let storedRecord = try await db.pool.read { connection in
            try AccountRecord.fetchOne(connection, key: current.id)
        }
        let record = try #require(storedRecord)
        #expect(record.signature == rich.plainText)
        #expect(record.signatureJSON != nil)
        #expect(record.account.emailSignature == rich)

        // Uma instalação migrada de v1 não tem JSON para a conta já existente.
        // A nova leitura deve abrir a assinatura anterior em vez de apagá-la.
        try await db.pool.write { connection in
            try connection.execute(
                sql: """
                INSERT INTO account
                (id, address, displayName, provider, host, tintLightHex, tintDarkHex,
                 signature, state, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "conta-legada", "legacy@example.com", "Legacy", "imap", "example",
                    "#111111", "#eeeeee", "Assinatura anterior", "ativa", 1.0
                ]
            )
        }
        let storedLegacy = try await db.pool.read { connection in
            try AccountRecord.fetchOne(connection, key: "conta-legada")
        }
        let legacy = try #require(storedLegacy)
        #expect(legacy.signatureJSON == nil)
        #expect(legacy.account.emailSignature == EmailSignature(legacyText: "Assinatura anterior"))
    }

    @Test("MIME aninha related dentro de alternative e mixed")
    func nestedMimeWithAttachmentAndCID() throws {
        let rich = try signature()
        let attachment = try OutgoingAttachment(
            filename: "contrato.pdf", mimeType: "application/pdf", data: Data([1, 2, 3])
        )
        let message = OutgoingMessage(
            messageID: "rich@x.com", accountID: "conta-rica",
            from: OutgoingAddress(name: "Marcos", address: "marcos@example.com"),
            to: [OutgoingAddress(name: "Cliente", address: "cliente@example.com")],
            subject: "Proposta", plainText: rich.plainText, html: rich.html,
            attachments: [attachment], inlineResources: rich.inlineResources
        )
        let raw = OutgoingMime.compose(
            message, date: Date(timeIntervalSince1970: 1), includeBcc: false, boundary: "outer"
        )
        #expect(raw.contains("Content-Type: multipart/mixed; boundary=\"outer\""))
        #expect(raw.contains("Content-Type: multipart/alternative; boundary=\"outer-alt\""))
        #expect(raw.contains("Content-Type: multipart/related; boundary=\"outer-alt-related\"; type=\"text/html\""))
        #expect(raw.contains("Content-ID: <logo@inline.local>"))
        #expect(raw.contains("Content-Disposition: inline; filename=\"signature-image-1.png\""))
        #expect(raw.contains("Content-Disposition: attachment; filename*=utf-8''contrato.pdf"))
        let plain = try #require(raw.range(of: "Content-Type: text/plain"))
        let html = try #require(raw.range(of: "Content-Type: text/html"))
        let resource = try #require(raw.range(of: "Content-ID: <logo@inline.local>"))
        #expect(plain.lowerBound < html.lowerBound)
        #expect(html.lowerBound < resource.lowerBound)
    }

    @Test("cópia local de Enviadas preserva HTML")
    func sentCopyPreservesHTML() throws {
        let rich = try signature()
        let outgoing = OutgoingMessage(
            messageID: "sent@x.com", accountID: "conta-rica",
            from: OutgoingAddress(name: "Marcos", address: "marcos@example.com"),
            to: [OutgoingAddress(name: "Cliente", address: "cliente@example.com")],
            subject: "Proposta", plainText: rich.plainText, html: rich.html,
            inlineResources: rich.inlineResources
        )
        let sent = SentCopy.linhas(
            outgoing, gravadaEm: .gmail(serverID: "server-1"), accountID: "conta-rica",
            now: Date(timeIntervalSince1970: 1), threadKey: "thread"
        ).message
        #expect(sent.bodyHTML == rich.html)
        #expect(sent.htmlResolved)
    }

    @Test("diretor, modelo e status atravessam a assinatura estruturada")
    @MainActor
    func updatesThroughAccountSurface() async throws {
        let db = try SyncDatabase.temporary()
        let old = EmailSignature(legacyText: "Assinatura antiga")
        let current = account(signature: old)
        try await db.pool.write { connection in
            try AccountRecord(current, createdAt: Date(timeIntervalSince1970: 1)).insert(connection)
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let director = AccountDirector(
            database: db, secrets: InMemorySecretStore(), auth: nil,
            session: StubURLProtocol.session(), eventLoopGroup: group,
            imapConnect: { _, _ in throw SyncError.rede("não usado") }
        )
        let model = AccountsModel(director: director)
        let rich = try signature()

        #expect(await model.updateEmailSignature(accountID: current.id, signature: rich))
        #expect(model.lastError == nil)

        let stored = try await db.pool.read { connection in
            try AccountRecord.fetchOne(connection, key: current.id)
        }
        let storedAccount = try #require(stored)
        #expect(storedAccount.account.emailSignature == rich)

        let status = AccountStatus(
            accountID: current.id, address: current.address, hostMark: current.host,
            state: .ativa, messageCount: 0, lastSyncedAt: nil,
            error: nil, progress: nil, emailSignature: rich
        )
        #expect(status.signature == rich.plainText)
        #expect(status.emailSignature == rich)
    }
}

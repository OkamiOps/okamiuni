import Foundation
import GRDB
import UNICore

/// Busca sob demanda de um anexo. IMAP já deixou os bytes no cache local quando
/// o corpo MIME foi lido; Gmail só baixa `attachmentId` depois do clique.
public actor DatabaseAttachmentFetcher: AttachmentFetching {
    private let database: SyncDatabase
    private let auth: GoogleAuth?
    private let session: URLSession
    private let gmailBaseURL: URL

    public init(
        database: SyncDatabase,
        auth: GoogleAuth?,
        session: URLSession,
        gmailBaseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
    ) {
        self.database = database
        self.auth = auth
        self.session = session
        self.gmailBaseURL = gmailBaseURL
    }

    public func fetchAttachment(
        accountID: String, messageID: String, attachmentID: String
    ) async throws -> FetchedAttachment {
        guard let record = try await database.pool.read({ db in
            try MessageAttachmentRecord
                .filter(Column("id") == attachmentID && Column("messageID") == messageID)
                .fetchOne(db)
        }) else { throw AttachmentError.unavailable }

        guard record.byteCount <= OutgoingAttachment.maximumByteCount else {
            throw AttachmentError.fileTooLarge(limit: OutgoingAttachment.maximumByteCount)
        }
        if let data = record.data { return try FetchedAttachment(attachment: record.attachment, data: data) }
        guard let remoteID = record.remoteID,
              let account = try await database.pool.read({ db in
                  try AccountRecord.fetchOne(db, key: accountID)?.account
              }), account.provider == .gmail,
              let auth else { throw AttachmentError.unavailable }

        guard let serverID = MessageIdentity.parse(messageID, accountID: accountID).flatMap({ coordinate in
            if case .gmail(let id) = coordinate { return id }
            return nil
        }) else { throw AttachmentError.unavailable }

        let client = GmailClient(
            session: session,
            accessToken: { try await auth.accessToken(for: accountID) },
            baseURL: gmailBaseURL
        )
        let data = try await client.attachment(messageID: serverID, attachmentID: remoteID)
        guard data.count == record.byteCount else { throw AttachmentError.sizeMismatch }
        let cached = MessageAttachmentRecord(
            id: record.id, messageID: record.messageID, filename: record.filename,
            mimeType: record.mimeType, byteCount: record.byteCount,
            remoteID: record.remoteID, data: data
        )
        try await database.pool.write { db in try cached.update(db) }
        return try FetchedAttachment(attachment: cached.attachment, data: data)
    }
}

import Foundation

/// Os metadados de um arquivo que chegou numa mensagem.
///
/// Os bytes não moram na lista de mensagens: uma caixa com PDFs grandes não
/// pode colocar dezenas de megabytes no estado da interface só para desenhar
/// três chips. Eles só são buscados quando a pessoa pede para salvar o arquivo.
public struct MailAttachment: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let filename: String
    public let mimeType: String
    public let byteCount: Int

    public init(id: String, filename: String, mimeType: String, byteCount: Int) {
        self.id = id
        self.filename = AttachmentName.sanitize(filename)
        self.mimeType = AttachmentName.mimeType(mimeType)
        self.byteCount = max(0, byteCount)
    }

    public var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    /// Convite de agenda disfarçado de arquivo: Gmail entrega `invite.ics`
    /// como anexo, e recusar o rótulo deixava o cartão fora do leitor.
    public var looksLikeCalendarInvite: Bool {
        Self.looksLikeCalendarInvite(filename: filename, mimeType: mimeType)
    }

    public static func looksLikeCalendarInvite(filename: String, mimeType: String) -> Bool {
        let mime = mimeType.lowercased()
        let nome = filename.lowercased()
        return mime == "text/calendar" || mime == "application/ics" || mime == "text/x-vcalendar"
            || nome.hasSuffix(".ics") || nome.hasSuffix(".ifb")
    }
}

/// Um arquivo pronto para entrar numa mensagem de saída.
///
/// A fila de saída o serializa no banco até o SMTP/Gmail confirmar o envio;
/// por isso os bytes são `Codable`, mas a porta de seleção recusa arquivos que
/// fariam essa fila transformar o banco local em depósito sem limite.
public struct OutgoingAttachment: Codable, Sendable, Hashable, Identifiable {
    /// 25 MiB é menor que os limites usuais de provedores depois do custo do
    /// base64 (~33%) e evita que uma escolha acidental esgote a memória.
    public static let maximumByteCount = 25 * 1_024 * 1_024

    public let id: String
    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(
        id: String = UUID().uuidString.lowercased(),
        filename: String,
        mimeType: String = "application/octet-stream",
        data: Data
    ) throws {
        guard !data.isEmpty else { throw AttachmentError.emptyFile }
        guard data.count <= Self.maximumByteCount else {
            throw AttachmentError.fileTooLarge(limit: Self.maximumByteCount)
        }
        self.id = id
        self.filename = AttachmentName.sanitize(filename)
        self.mimeType = AttachmentName.mimeType(mimeType)
        self.data = data
    }

    public var metadata: MailAttachment {
        MailAttachment(id: id, filename: filename, mimeType: mimeType, byteCount: data.count)
    }
}

/// O resultado de buscar um anexo recebido, ainda antes de o usuário escolher
/// o local final. A porta de salvamento é injetável justamente para o harness
/// testar esta transição sem abrir um painel do macOS.
public struct FetchedAttachment: Sendable, Hashable {
    public let attachment: MailAttachment
    public let data: Data

    public init(attachment: MailAttachment, data: Data) throws {
        guard data.count == attachment.byteCount else { throw AttachmentError.sizeMismatch }
        guard data.count <= OutgoingAttachment.maximumByteCount else {
            throw AttachmentError.fileTooLarge(limit: OutgoingAttachment.maximumByteCount)
        }
        self.attachment = attachment
        self.data = data
    }
}

public protocol AttachmentSelecting: Sendable {
    /// Abre a escolha de arquivo (ou a substituição de teste) e devolve os
    /// bytes que a pessoa autorizou anexar.
    @MainActor func selectAttachments() async throws -> [OutgoingAttachment]
}

public protocol AttachmentFetching: Sendable {
    /// Busca somente o anexo solicitado e deixa a implementação reutilizar o
    /// cache local, Gmail ou IMAP conforme a origem da mensagem.
    func fetchAttachment(accountID: String, messageID: String, attachmentID: String) async throws -> FetchedAttachment
}

public protocol AttachmentSaving: Sendable {
    /// Persiste o arquivo já baixado no destino que a pessoa escolheu.
    @MainActor func save(_ attachment: FetchedAttachment) async throws
}

public enum AttachmentError: Error, Sendable, Equatable, LocalizedError {
    case emptyFile
    case fileTooLarge(limit: Int)
    case sizeMismatch
    case unavailable
    case unsafeFilename

    public var errorDescription: String? {
        switch self {
        case .emptyFile: "O arquivo está vazio."
        case .fileTooLarge(let limit):
            "O anexo passa do limite de \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
        case .sizeMismatch: "O anexo baixado não tem o tamanho anunciado pela mensagem."
        case .unavailable: "Este anexo não está mais disponível no servidor."
        case .unsafeFilename: "O nome do arquivo não é seguro para salvar."
        }
    }
}

public enum AttachmentName {
    /// Remove caminho, controles e nomes reservados. O nome final continua
    /// legível, mas nunca pode escapar da pasta que a porta de salvamento abriu.
    public static func sanitize(_ raw: String) -> String {
        let lastComponent = raw
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").last.map(String.init) ?? ""
        let filtered = lastComponent.unicodeScalars.filter {
            $0.properties.generalCategory != .control && $0 != ":" && $0 != "/" && $0 != "\\"
        }
        let compact = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(180)
        let candidate = String(compact)
        if candidate.isEmpty || candidate == "." || candidate == ".." { return "anexo" }
        return candidate
    }

    public static func mimeType(_ raw: String) -> String {
        let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains("/"), !value.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return "application/octet-stream"
        }
        return value
    }
}

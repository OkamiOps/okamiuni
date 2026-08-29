import Foundation
import Testing
@testable import UNICore

@Suite("Anexos: limites e nomes")
struct MailAttachmentTests {
    @Test("nome vindo da rede não atravessa a pasta escolhida")
    func sanitizesFilename() {
        #expect(AttachmentName.sanitize("../../relatorio.pdf") == "relatorio.pdf")
        #expect(AttachmentName.sanitize("\u{0000}") == "anexo")
    }

    @Test("arquivo acima do teto é recusado antes de entrar na fila")
    func rejectsOversizedOutgoingFile() {
        #expect(throws: AttachmentError.fileTooLarge(limit: OutgoingAttachment.maximumByteCount)) {
            try OutgoingAttachment(
                filename: "grande.bin",
                data: Data(repeating: 0, count: OutgoingAttachment.maximumByteCount + 1)
            )
        }
    }

    @Test("rascunho com arquivo e destinatário pode ser enviado sem texto")
    func attachmentOnlyReplyCanSend() throws {
        let file = try OutgoingAttachment(filename: "proposta.pdf", data: Data([1]))
        let draft = ReplyDraft(
            to: [Contact(name: "Ana", address: "ana@example.com")], attachments: [file]
        )
        #expect(QuickReply.canSend(draft))
    }
}

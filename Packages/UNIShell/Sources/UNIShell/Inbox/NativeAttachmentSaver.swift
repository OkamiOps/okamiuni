import AppKit
import Foundation
import UNICore

/// Adaptador de produção do destino de um download. A URL só vem do
/// `NSSavePanel` acionado pela pessoa; testes injetam uma porta em memória.
public struct NativeAttachmentSaver: AttachmentSaving {
    public init() {}

    @MainActor
    public func save(_ attachment: FetchedAttachment) async throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.attachment.filename
        panel.prompt = L10n.tr("Salvar")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try attachment.data.write(to: url, options: .atomic)
    }
}

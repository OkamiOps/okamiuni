import AppKit
import Foundation
import UniformTypeIdentifiers
import UNICore

/// Adaptador de produção do seletor. O `NSOpenPanel` só é criado pela ação do
/// usuário; testes passam uma porta em memória e nunca tocam o desktop.
struct NativeAttachmentSelector: AttachmentSelecting {
    @MainActor
    func selectAttachments() async throws -> [OutgoingAttachment] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Anexar"
        guard panel.runModal() == .OK else { return [] }
        return try panel.urls.map { url in
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?
                .preferredMIMEType ?? "application/octet-stream"
            return try OutgoingAttachment(filename: url.lastPathComponent, mimeType: type, data: data)
        }
    }
}

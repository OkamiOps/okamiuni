import Foundation
import Testing
import UNICore
@testable import UNISync

@Suite("HTML de rascunhos do agente")
struct AgentDraftHTMLTests {
    @Test("preserva tabela, estilo, CID e metadado da assinatura")
    func preservesDraftPresentation() throws {
        let html = #"<style>td { padding: 8px; }</style><table><tr><td>Texto</td><td><img src="cid:Logo-1" width="120"></td></tr></table><!--okamiuni-signature:fixture-->"#
        let sanitized = try MimeSanitize.sanitizeDraft(html: html)
        #expect(sanitized.contains("<table>"))
        #expect(sanitized.contains("padding: 8px"))
        #expect(sanitized.contains(#"src="cid:Logo-1""#))
        #expect(sanitized.contains("<!--okamiuni-signature:fixture-->"))
        #expect(!sanitized.contains(MimeSanitize.placeholder))
    }

    @Test("remove URLs executáveis codificadas, arquivos locais e handlers")
    func removesEncodedExecution() throws {
        let html = #"<p onclick="bad()">Seguro</p><a href="&#106;avascript:bad()">Link</a><img src="file:///private/image.png" onerror="bad()"><iframe srcdoc="bad">bad</iframe><script>bad()</script><!--untrusted comment-->"#
        let sanitized = try MimeSanitize.sanitizeDraft(html: html)
        #expect(sanitized.contains("Seguro"))
        #expect(sanitized.contains("Link"))
        for unsafe in ["bad", "onclick", "onerror", "file:", "avascript", "srcdoc", "iframe", "<script", "untrusted comment"] {
            #expect(!sanitized.contains(unsafe))
        }
    }

    @Test("as ferramentas usadas pelo aplicativo aplicam o parser compartilhado antes de persistir")
    @MainActor
    func compositionUsesScanner() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        let account = try #require(store.accounts.first)
        let tools = AgentApplicationServices().tools(store: store)
        let saved = try await tools.execute(name: "drafts_create_html", arguments: .object([
            "accountID": .string(account.id), "subject": .string("HTML"), "body": .string("Seguro"),
            "html": .string(#"<p>Seguro</p><a href="&#106;avascript:bad()">Link</a>"#),
            "to": .array([.string("review@example.com")]), "requestID": .string("html-parser-fixture")
        ]))
        let id = try #require(saved["draftID"]?.stringValue)
        let draft = try #require(store.message(id))
        #expect(draft.bodyHTML?.contains("<p>Seguro</p>") == true)
        #expect(draft.bodyHTML?.contains("bad") == false)
    }
}

import Foundation
import Testing
import UNICore
@testable import UNIShell

/// As decisões da lista de pastas do Vidro, sem montar barra nenhuma.
@Suite("Pastas no shell Vidro")
struct GlassFolderListTests {

    private func pasta(
        _ id: String, _ nome: String, role: FolderRole = .other, unread: Int = 0
    ) -> MailFolder {
        MailFolder(
            id: id, accountID: "c1", serverName: nome, displayName: nome,
            role: role, unreadCount: unread
        )
    }

    @Test("as sete caixas do protótipo, nesta ordem e sem 'Tudo'")
    func bucketOrder() {
        #expect(GlassFolderList.buckets == [
            .today, .later, .sent, .drafts, .archived, .junk, .trash,
        ])
        #expect(!GlassFolderList.buckets.contains(.all))
    }

    @Test("só o Spam escreve o número como aviso")
    func onlyJunkWarns() {
        for bucket in GlassFolderList.buckets {
            #expect(GlassFolderList.countIsWarning(bucket) == (bucket == .junk))
        }
    }

    /// **A mutação:** devolver `depth: 0` sempre faz "Clientes/Faturas"
    /// aparecer inteira e sem recuo — que é exatamente a linha cortada ao meio
    /// de que a fase 2 veio se livrar.
    @Test("o caminho vira árvore quando o pai está na lista")
    func nestedPathBecomesTree() {
        let linhas = GlassFolderList.tree([
            pasta("i", "INBOX", role: .inbox),
            pasta("c", "Clientes"),
            pasta("cf", "Clientes/Faturas"),
        ])
        #expect(linhas.map(\.label) == ["INBOX", "Clientes", "Faturas"])
        #expect(linhas.map(\.depth) == [0, 0, 1])
    }

    @Test("sem o pai na lista, a pasta fica na raiz com o caminho inteiro")
    func orphanKeepsFullPath() {
        let linhas = GlassFolderList.tree([pasta("cf", "Clientes/Faturas")])
        #expect(linhas.map(\.label) == ["Clientes/Faturas"])
        #expect(linhas.map(\.depth) == [0])
    }

    private func mensagem(
        _ id: String, folders: [String], precisa: Bool
    ) -> Message {
        Message(
            id: id, accountID: "c1",
            from: Contact(name: "Marina", address: "marina@cliente.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: "Proposta", snippet: "Trecho", body: [],
            tags: precisa ? [UNICore.Tag(name: InboxWaitingLine.legacyNeedsReplyTag, tintHex: nil)] : [],
            bucket: .today, isRead: false, summary: nil, detectedEvent: nil,
            folderIDs: folders
        )
    }

    @Test("o recado conta quem pede resposta fora da entrada")
    func misplacedCounts() throws {
        let pastas = [
            pasta("i", "INBOX", role: .inbox),
            pasta("p", "Promoções"),
            pasta("a", "Atualizações"),
        ]
        let recado = try #require(GlassFolderList.misplaced(
            messages: [
                mensagem("m1", folders: ["p"], precisa: true),
                mensagem("m2", folders: ["a"], precisa: true),
                // Na entrada: não está perdida.
                mensagem("m3", folders: ["i"], precisa: true),
                // Fora da entrada, mas ninguém espera resposta dela.
                mensagem("m4", folders: ["p"], precisa: false),
            ],
            folders: pastas
        ))
        #expect(recado.count == 2)
        #expect(recado.messageIDs == ["m1", "m2"])
        #expect(recado.folderNames == ["Promoções", "Atualizações"])
        #expect(recado.sentence.contains("Promoções"))
    }

    /// Sem conta conectada não há pasta de provedor nenhuma — e é assim que o
    /// cartão não aparece nos retratos das fixtures.
    @Test("sem pastas, não há recado")
    func noFoldersNoNote() {
        #expect(GlassFolderList.misplaced(
            messages: [mensagem("m1", folders: [], precisa: true)], folders: []
        ) == nil)
    }
}

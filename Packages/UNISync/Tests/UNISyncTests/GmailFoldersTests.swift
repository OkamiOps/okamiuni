import Foundation
import Testing
import UNICore
@testable import UNISync

/// Quais rótulos do Gmail viram pasta, e onde cada mensagem está.
///
/// Tabela pura, sem banco e sem rede — a mesma forma de `FolderRolesTests`, e
/// pela mesma razão: é a peça que mais varia com o provedor e a que mais vai
/// precisar de conserto.
@Suite("As pastas de uma conta Gmail")
struct GmailFoldersTests {
    private func rotulo(_ id: String, _ nome: String, sistema: Bool) -> GmailLabel {
        GmailLabel(id: id, name: nome, type: sistema ? "system" : "user")
    }

    @Test("Os cinco rótulos do sistema que são lugares viram pasta, com papel")
    func sistemaComPapel() {
        let pastas = GmailFolders.records(
            [
                rotulo("INBOX", "INBOX", sistema: true),
                rotulo("SENT", "SENT", sistema: true),
                rotulo("DRAFT", "DRAFT", sistema: true),
                rotulo("SPAM", "SPAM", sistema: true),
                rotulo("TRASH", "TRASH", sistema: true),
            ],
            accountID: "c1"
        )
        #expect(pastas.count == 5)
        let porPapel = Dictionary(
            uniqueKeysWithValues: pastas.compactMap(\.folder).map { ($0.role, $0.displayName) }
        )
        #expect(porPapel[.inbox] == "Entrada")
        #expect(porPapel[.sent] == "Enviados")
        #expect(porPapel[.drafts] == "Rascunhos")
        #expect(porPapel[.junk] == "Spam")
        #expect(porPapel[.trash] == "Lixeira")
    }

    /// **A mutação:** deixar `isFolderLabel` devolver `true` para tudo põe
    /// "UNREAD", "STARRED", "IMPORTANT", "CHAT" e as quatro abas
    /// `CATEGORY_*` na barra lateral — oito linhas com cara de pasta que não
    /// guardam nada que `INBOX` já não guarde.
    @Test("Estado e aba não são pasta: UNREAD, STARRED, IMPORTANT, CHAT e CATEGORY_*")
    func estadoNaoEhPasta() {
        let entrada = [
            rotulo("UNREAD", "UNREAD", sistema: true),
            rotulo("STARRED", "STARRED", sistema: true),
            rotulo("IMPORTANT", "IMPORTANT", sistema: true),
            rotulo("CHAT", "CHAT", sistema: true),
            rotulo("CATEGORY_PROMOTIONS", "CATEGORY_PROMOTIONS", sistema: true),
            rotulo("CATEGORY_SOCIAL", "CATEGORY_SOCIAL", sistema: true),
        ]
        #expect(GmailFolders.records(entrada, accountID: "c1").isEmpty)
        for label in entrada {
            #expect(!GmailFolders.isFolderLabel(label.id), "\(label.id) não é um lugar")
        }
    }

    @Test("O rótulo do usuário é pasta, com o nome que a pessoa deu")
    func rotuloDoUsuario() throws {
        let pastas = GmailFolders.records(
            [rotulo("Label_17", "Clientes/Faturas", sistema: false)], accountID: "c1"
        )
        let pasta = try #require(pastas.first?.folder)
        #expect(pasta.displayName == "Clientes/Faturas")
        #expect(pasta.role == .other)
        // O `serverName` é o **id** do rótulo, e não o nome: renomear "Faturas"
        // no webmail tem de atualizar esta linha, não criar uma segunda ao lado
        // com as mensagens partidas em duas.
        #expect(pasta.serverName == "Label_17")
        #expect(pasta.id == FolderRecord.id(accountID: "c1", serverName: "Label_17"))
    }

    /// **A mutação:** devolver `[]` de `membership` faz toda pasta da conta
    /// Gmail abrir vazia — a linha existe na barra e nenhuma mensagem se diz
    /// dela.
    @Test("A mensagem está nas pastas dos rótulos que ela carrega, e só nelas")
    func pertinencia() {
        let ids = GmailFolders.membership(
            labelIDs: ["INBOX", "UNREAD", "Label_17", "CATEGORY_PROMOTIONS"], accountID: "c1"
        )
        #expect(ids == [
            FolderRecord.id(accountID: "c1", serverName: "INBOX"),
            FolderRecord.id(accountID: "c1", serverName: "Label_17"),
        ])
    }
}

import Foundation
import Testing
@testable import UNISync

@Suite("O papel de uma pasta")
struct FolderRolesTests {
    @Test("SPECIAL-USE manda, quando o servidor dá")
    func specialUseManda() {
        #expect(FolderRoles.role(specialUse: "\\Archive", name: "Coisas") == .archive)
        #expect(FolderRoles.role(specialUse: "\\All", name: "Coisas") == .archive)
        #expect(FolderRoles.role(specialUse: "\\Trash", name: "Coisas") == .trash)
        #expect(FolderRoles.role(specialUse: "\\Sent", name: "Coisas") == .sent)
        // Rascunhos e spam existem no servidor e não têm papel nosso.
        #expect(FolderRoles.role(specialUse: "\\Drafts", name: "Rascunhos") == .other)
        #expect(FolderRoles.role(specialUse: "\\Junk", name: "Spam") == .other)
        // A caixa maiúscula do atributo não pode mudar a resposta.
        #expect(FolderRoles.role(specialUse: "\\arCHive", name: "Coisas") == .archive)
    }

    @Test("Sem SPECIAL-USE, o nome decide — em português, inglês e no formato do Gmail")
    func nomeDecide() {
        #expect(FolderRoles.role(specialUse: nil, name: "INBOX") == .inbox)
        #expect(FolderRoles.role(specialUse: nil, name: "Caixa de entrada") == .inbox)
        #expect(FolderRoles.role(specialUse: nil, name: "Arquivo") == .archive)
        #expect(FolderRoles.role(specialUse: nil, name: "Archive") == .archive)
        #expect(FolderRoles.role(specialUse: nil, name: "[Gmail]/Todos os e-mails") == .archive)
        #expect(FolderRoles.role(specialUse: nil, name: "[Gmail]/All Mail") == .archive)
        #expect(FolderRoles.role(specialUse: nil, name: "Lixeira") == .trash)
        #expect(FolderRoles.role(specialUse: nil, name: "Deleted Messages") == .trash)
        #expect(FolderRoles.role(specialUse: nil, name: "Enviados") == .sent)
        #expect(FolderRoles.role(specialUse: nil, name: "Sent Items") == .sent)
        #expect(FolderRoles.role(specialUse: nil, name: "Projetos/2026") == .other)
    }

    @Test("O acento não muda a resposta: 'Lixeira' e 'lixeira' são a mesma pasta")
    func nomeDobraAcentoECaixa() {
        #expect(FolderRoles.role(specialUse: nil, name: "lixeira") == .trash)
        #expect(FolderRoles.role(specialUse: nil, name: "ARQUIVO") == .archive)
        #expect(FolderRoles.role(specialUse: nil, name: "Todos os e-mails") == .archive)
    }

    @Test("A lixeira do Outlook/Office365 tem nome próprio: 'Deleted Items'")
    func lixeiraDoOutlook() {
        // outlook.com, hotmail.com e live.com estão nos presets (Task 6); se o
        // servidor não anunciar SPECIAL-USE \Trash, é este nome que decide.
        #expect(FolderRoles.role(specialUse: nil, name: "Deleted Items") == .trash)
        #expect(FolderRoles.role(specialUse: nil, name: "deleted items") == .trash)
    }

    @Test("A pasta `OkamiUNI/Depois` é reconhecida quando existir de instalação anterior")
    func pastaDepois() {
        #expect(FolderRoles.laterFolderName == "OkamiUNI/Depois")
        #expect(FolderRoles.role(specialUse: nil, name: "OkamiUNI/Depois") == .later)
        #expect(FolderRoles.role(specialUse: nil, name: "okamiuni/depois") == .later)
        // E o SPECIAL-USE não a atropela: o servidor não tem atributo para ela,
        // mas se marcasse a pasta como arquivo, o nosso nome ainda ganha —
        // é a nossa pasta, criada por nós, com significado nosso.
        #expect(FolderRoles.role(specialUse: "\\Archive", name: "OkamiUNI/Depois") == .later)
    }
}

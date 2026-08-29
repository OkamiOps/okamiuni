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
        // Rascunhos e spam ganharam papel na M3-17 — pelo ícone da linha na
        // barra lateral, e não por caixa: os dois continuam indo para
        // Arquivado, com o nome da pasta como etiqueta. Ver `TriageProjection`.
        #expect(FolderRoles.role(specialUse: "\\Drafts", name: "Rascunhos") == .drafts)
        #expect(FolderRoles.role(specialUse: "\\Junk", name: "Spam") == .junk)
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

    /// **A mutação:** apagar os dois laços de sufixo de `drafts`/`junk` em
    /// `FolderRoles` devolve `.other` para as duas, e a linha delas na barra
    /// lateral perde o ícone — "Rascunhos" fica indistinguível de uma pasta
    /// qualquer que a pessoa criou.
    @Test("Rascunhos e spam pelo nome, quando o servidor não anuncia SPECIAL-USE")
    func rascunhosESpamPeloNome() {
        #expect(FolderRoles.role(specialUse: nil, name: "Drafts") == .drafts)
        #expect(FolderRoles.role(specialUse: nil, name: "Rascunhos") == .drafts)
        #expect(FolderRoles.role(specialUse: nil, name: "[Gmail]/Rascunhos") == .drafts)
        #expect(FolderRoles.role(specialUse: nil, name: "Spam") == .junk)
        #expect(FolderRoles.role(specialUse: nil, name: "Junk Email") == .junk)
        #expect(FolderRoles.role(specialUse: nil, name: "Lixo eletrônico") == .junk)
        // E o papel novo não mexeu em caixa nenhuma: as duas continuam em
        // Arquivado, com o nome da pasta como etiqueta — exatamente onde
        // estavam quando eram `.other`.
        #expect(TriageProjection.bucket(role: .drafts) == .archived)
        #expect(TriageProjection.bucket(role: .junk) == .archived)
        #expect(TriageProjection.tag(folderRole: .drafts, folderName: "Rascunhos")?.name == "Rascunhos")
        #expect(TriageProjection.tag(folderRole: .junk, folderName: "Spam")?.name == "Spam")
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

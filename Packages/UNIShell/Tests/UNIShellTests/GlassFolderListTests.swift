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

    // MARK: - O recado da IA

    /// "agora" fixo, para a janela de sete dias não depender do relógio da
    /// máquina que roda o teste.
    private static let agora = Date(timeIntervalSince1970: 1_800_000_000)

    private func mensagem(
        _ id: String, folders: [String], precisa: Bool,
        diasAtras: Double = 1, lida: Bool = false
    ) -> Message {
        Message(
            id: id, accountID: "c1",
            from: Contact(name: "Marina", address: "marina@cliente.com"),
            receivedAt: Self.agora.addingTimeInterval(-diasAtras * 86_400),
            subject: "Proposta", snippet: "Trecho", body: [],
            tags: precisa ? [UNICore.Tag(name: InboxWaitingLine.legacyNeedsReplyTag, tintHex: nil)] : [],
            bucket: .today, isRead: lida, summary: nil, detectedEvent: nil,
            folderIDs: folders
        )
    }

    /// As pastas da conta do dono, com os dois destinos automáticos de
    /// verdade (Spam pelo papel, Promoções pelo rótulo do Gmail) e as que a
    /// tela dele mostrava por engano.
    private var pastasDoDono: [MailFolder] {
        [
            pasta("i", "INBOX", role: .inbox),
            pasta("spam", "INBOX.Junk", role: .junk),
            pasta("promo", "CATEGORY_PROMOTIONS"),
            pasta("upd", "CATEGORY_UPDATES"),
            pasta("lixo", "INBOX.Trash", role: .trash),
            pasta("env", "INBOX.Sent", role: .sent),
            pasta("arq", "INBOX.Archive", role: .archive),
            pasta("minha", "00_Novos/Compras_Recibos"),
        ]
    }

    @Test("o recado conta quem pede resposta e o provedor jogou num canto")
    func misplacedCounts() throws {
        let recado = try #require(GlassFolderList.misplaced(
            messages: [
                mensagem("m1", folders: ["spam"], precisa: true),
                mensagem("m2", folders: ["promo"], precisa: true),
                // Na entrada: não está perdida.
                mensagem("m3", folders: ["i"], precisa: true),
                // Fora da entrada, mas ninguém espera resposta dela.
                mensagem("m4", folders: ["promo"], precisa: false),
            ],
            folders: pastasDoDono, now: Self.agora
        ))
        #expect(recado.count == 2)
        #expect(recado.messageIDs == ["m1", "m2"])
        #expect(recado.folderNames == ["Spam", "Promoções"])
        #expect(recado.sentence == "2 e-mails importantes caíram em Spam e Promoções")
    }

    /// **A reclamação de 15/10/2026, inteira.** A pasta que o dono criou é
    /// arrumação dele; lixeira, enviados e arquivo também. Nenhuma das quatro
    /// pode fazer o recado aparecer.
    @Test("pasta do dono, lixeira, enviados e arquivo nunca contam")
    func userFoldersAndSystemBoxesAreIgnored() {
        for id in ["minha", "lixo", "env", "arq"] {
            #expect(
                GlassFolderList.misplaced(
                    messages: [mensagem("m1", folders: [id], precisa: true)],
                    folders: pastasDoDono, now: Self.agora
                ) == nil,
                "\(id) não é destino automático do provedor"
            )
        }
    }

    /// Spam **e** uma pasta do dono: alguém a arquivou ali, e esse alguém é
    /// ele. Não é acidente do provedor.
    @Test("mensagem que o dono também arquivou não é acidente")
    func filedByTheOwnerIsNotMisplaced() {
        #expect(GlassFolderList.misplaced(
            messages: [mensagem("m1", folders: ["spam", "minha"], precisa: true)],
            folders: pastasDoDono, now: Self.agora
        ) == nil)
    }

    @Test("e-mail velho e e-mail já lido ficam de fora")
    func onlyFreshUnreadCounts() {
        #expect(GlassFolderList.misplaced(
            messages: [mensagem("m1", folders: ["spam"], precisa: true, diasAtras: 30)],
            folders: pastasDoDono, now: Self.agora
        ) == nil)
        #expect(GlassFolderList.misplaced(
            messages: [mensagem("m2", folders: ["spam"], precisa: true, lida: true)],
            folders: pastasDoDono, now: Self.agora
        ) == nil)
    }

    /// Uma pasta a mais que duas vira "e mais N": a frase é uma linha de
    /// barra lateral, não um parágrafo.
    @Test("a frase nomeia no máximo duas pastas")
    func sentenceNamesAtMostTwoFolders() throws {
        let pastas = pastasDoDono + [pasta("soc", "CATEGORY_SOCIAL")]
        let recado = try #require(GlassFolderList.misplaced(
            messages: [
                mensagem("m1", folders: ["spam"], precisa: true),
                mensagem("m2", folders: ["promo"], precisa: true),
                mensagem("m3", folders: ["upd"], precisa: true),
                mensagem("m4", folders: ["soc"], precisa: true),
            ],
            folders: pastas, now: Self.agora
        ))
        #expect(recado.count == 4)
        #expect(recado.sentence == "4 e-mails importantes caíram em Spam e Promoções e mais 2")
    }

    /// Caminho cru nunca chega à frase.
    @Test("o caminho do servidor vira nome legível")
    func rawPathIsPrettified() {
        #expect(GlassFolderList.nomeLegivel(pasta("j", "INBOX.Junk", role: .junk)) == "Spam")
        #expect(GlassFolderList.nomeLegivel(pasta("p", "CATEGORY_PROMOTIONS")) == "Promoções")
        #expect(GlassFolderList.nomeLegivel(pasta("c", "Clientes/Faturas")) == "Faturas")
    }

    /// Nome não prova nada: só o formato do provedor prova. "Promocao" é
    /// pasta do dono mesmo escrita quase igual à aba do Gmail.
    @Test("pasta chamada Promoções pelo dono não é aba do Gmail")
    func lookalikeUserFolderIsNotAGmailCategory() {
        #expect(GlassFolderList.categoriaDoGmail(pasta("x", "00_Novos/Promocao")) == nil)
        #expect(GlassFolderList.categoriaDoGmail(pasta("y", "Promoções")) == nil)
        #expect(GlassFolderList.categoriaDoGmail(pasta("z", "CATEGORY_SOCIAL")) == "Social")
    }

    /// Sem conta conectada não há pasta de provedor nenhuma — e é assim que o
    /// cartão não aparece nos retratos das fixtures.
    @Test("sem pastas, não há recado")
    func noFoldersNoNote() {
        #expect(GlassFolderList.misplaced(
            messages: [mensagem("m1", folders: [], precisa: true)], folders: [],
            now: Self.agora
        ) == nil)
    }
}

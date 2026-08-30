import Foundation
import Testing
@testable import UNICore

/// As pastas do provedor dentro do `MailStore`: a lista de uma conta, o
/// contador, o filtro e o recolhível.
@Suite("As pastas do provedor")
@MainActor
struct FolderFilterTests {
    /// Uma fonte com pastas. `InMemoryMailSource` não tem servidor nenhum e
    /// devolve `[]` — é justamente o que faz o app sem conta continuar sem
    /// seção de pastas, e por isso o teste precisa da sua.
    private struct FonteComPastas: MailSource {
        var contas: [Account]
        var mensagens: [Message]
        var pastas: [MailFolder]

        func accounts() async throws -> [Account] { contas }
        func messages() async throws -> [Message] { mensagens }
        func agenda() async throws -> [AgendaItem] { [] }
        func pendingItems() async throws -> [PendingItem] { [] }
        func folders() async throws -> [MailFolder] { pastas }
    }

    private static let conta = Account(
        id: "c1", address: "marcos@okamiops.com", displayName: "Trabalho",
        provider: .imap, host: "okamiops",
        tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
    )
    private static let outraConta = Account(
        id: "c2", address: "ricardo@gmail.com", displayName: "Pessoal",
        provider: .gmail, host: "gmail",
        tintLightHex: "#725B9A", tintDarkHex: "#C2A7F4"
    )

    private static func pasta(
        _ nome: String, conta: String = "c1", role: FolderRole = .other
    ) -> MailFolder {
        MailFolder(
            id: "\(conta)/\(nome)", accountID: conta, serverName: nome,
            displayName: nome, role: role
        )
    }

    private static func mensagem(
        _ id: String, conta: String = "c1", pastas: [String],
        lida: Bool = false, bucket: TriageBucket = .archived
    ) -> Message {
        Message(
            id: id, accountID: conta,
            from: Contact(name: "Marina", address: "marina@clientepremium.com"),
            receivedAt: Date(timeIntervalSince1970: 1_799_000_000),
            subject: "Assunto \(id)", snippet: "Trecho", body: [], tags: [],
            bucket: bucket, isRead: lida, summary: nil, detectedEvent: nil,
            folderIDs: pastas.map { "\(conta)/\($0)" }
        )
    }

    private func store() async -> MailStore {
        let store = MailStore(source: FonteComPastas(
            contas: [Self.conta, Self.outraConta],
            mensagens: [
                Self.mensagem("m1", pastas: ["Faturas"]),
                Self.mensagem("m2", pastas: ["Faturas"], lida: true),
                Self.mensagem("m3", pastas: ["INBOX"], bucket: .today),
                Self.mensagem("m4", conta: "c2", pastas: ["Label_9"]),
                // **Da mesma conta, noutra pasta, na mesma caixa.** Sem ela o
                // filtro de conta sozinho já daria a resposta certa, e apagar o
                // filtro de pasta passaria despercebido — o teste passaria por
                // coincidência.
                Self.mensagem("m5", pastas: ["INBOX"]),
            ],
            pastas: [
                Self.pasta("Faturas"),
                Self.pasta("INBOX", role: .inbox),
                Self.pasta("Label_9", conta: "c2"),
            ]
        ))
        await store.load()
        return store
    }

    // MARK: A lista da conta

    @Test("As pastas são da conta, ordenadas com as de papel na frente")
    func pastasDaConta() async {
        let store = await store()
        let daPrimeira = store.folders(of: "c1")
        #expect(daPrimeira.map(\.displayName) == ["INBOX", "Faturas"])
        #expect(store.folders(of: "c2").map(\.displayName) == ["Label_9"])
    }

    /// **A mutação:** trocar `!$0.isRead` por `true` em `unreadCount(inFolder:)`
    /// faz a barra escrever o total ao lado de cada pasta — o mesmo defeito que
    /// o dono viu na caixa "Hoje" (44 contra 6), agora por pasta.
    @Test("O contador da pasta conta as não lidas dela")
    func contadorDaPasta() async {
        let store = await store()
        #expect(store.unreadCount(inFolder: "c1/Faturas") == 1)
        #expect(store.folders(of: "c1").first { $0.displayName == "Faturas" }?.unreadCount == 1)
    }

    // MARK: O filtro

    /// **A mutação:** apagar o degrau `inFolder` de `visibleMessages` faz a
    /// lista mostrar a caixa inteira depois de clicar numa pasta — a pasta
    /// aberta sem efeito nenhum, que é o defeito que a M3-17 existe para
    /// consertar.
    @Test("Abrir uma pasta filtra a lista por ela")
    func filtraPorPasta() async {
        let store = await store()
        store.select(bucket: .archived)
        #expect(store.visibleMessages.count == 4)
        store.select(folder: "c1/Faturas")
        #expect(Set(store.visibleMessages.map(\.id)) == ["m1", "m2"])
    }

    /// A pasta é de uma conta: abrir "Faturas" da conta do trabalho não pode
    /// deixar a lista mostrando a conta pessoal junto.
    @Test("Abrir uma pasta acende o filtro da conta dela")
    func acendeAConta() async {
        let store = await store()
        store.select(folder: "c1/Faturas")
        #expect(store.selectedAccountID == "c1")
        #expect(store.foldersExpanded("c1"))
    }

    @Test("Clicar de novo na mesma pasta a fecha")
    func cliqueDuploDesliga() async {
        let store = await store()
        store.select(folder: "c1/Faturas")
        store.select(folder: "c1/Faturas")
        #expect(store.selectedFolderID == nil)
    }

    /// **A mutação:** tirar o `selectedFolderID = nil` de `select(account:)`
    /// deixa a lista filtrada por uma pasta de outra conta — vazia, sem nada na
    /// barra que explique por quê.
    @Test("Trocar de conta solta a pasta aberta")
    func trocarDeContaSoltaAPasta() async {
        let store = await store()
        store.select(folder: "c1/Faturas")
        store.select(account: "c2")
        #expect(store.selectedFolderID == nil)
    }

    /// **A mutação:** tirar a guarda de `apply(_:)` deixa o filtro apontando
    /// para uma pasta que já não existe, e a lista fica vazia para sempre —
    /// sem linha nenhuma na barra para clicar e desfazer.
    @Test("A pasta apagada no servidor solta o filtro")
    func pastaQueSumiuSoltaOFiltro() async {
        let store = await store()
        store.select(folder: "c1/Faturas")
        store.apply(MailSnapshot(
            accounts: [Self.conta], messages: [], agenda: [], pendingItems: [],
            folders: [Self.pasta("INBOX", role: .inbox)]
        ))
        #expect(store.selectedFolderID == nil)
    }

    // MARK: O recolhível

    /// **A mutação:** fazer `expandedAccountIDs` nascer com todas as contas
    /// dentro abre a barra de pastas sozinha, e a tela do Marco 1 deixa de ser
    /// a de sempre.
    @Test("As pastas de uma conta nascem recolhidas, e a seta as abre")
    func nascemRecolhidas() async {
        let store = await store()
        #expect(!store.foldersExpanded("c1"))
        store.toggleFolders(of: "c1")
        #expect(store.foldersExpanded("c1"))
        store.toggleFolders(of: "c1")
        #expect(!store.foldersExpanded("c1"))
    }

    /// Recolher é sobre espaço na barra, não sobre o que a lista mostra.
    @Test("Recolher a conta não desfaz o filtro de pasta")
    func recolherNaoDesfazOFiltro() async {
        let store = await store()
        store.select(folder: "c1/Faturas")
        store.toggleFolders(of: "c1")
        #expect(!store.foldersExpanded("c1"))
        #expect(store.selectedFolderID == "c1/Faturas")
    }

    // MARK: Ações do menu

    @Test("Mover para pasta IMAP troca a pertinência e a projeção local")
    func moveParaPasta() async throws {
        let store = await store()
        let message = try #require(store.messages.first { $0.id == "m3" })
        let target = try #require(store.folders.first { $0.id == "c1/Faturas" })

        store.place(message, in: target, mode: .move)

        let updated = try #require(store.messages.first { $0.id == "m3" })
        #expect(updated.folderIDs == ["c1/Faturas"])
        #expect(updated.bucket == .archived)
    }

    @Test("Aplicar marcador Gmail preserva os marcadores existentes")
    func aplicaMarcador() async throws {
        let store = await store()
        let message = try #require(store.messages.first { $0.id == "m4" })
        let target = Self.pasta("Cliente", conta: "c2")

        store.place(message, in: target, mode: .label)

        let updated = try #require(store.messages.first { $0.id == "m4" })
        #expect(updated.folderIDs == ["c2/Label_9", "c2/Cliente"])
        #expect(updated.bucket == .archived)
    }

    @Test("Mover no Gmail troca só o marcador de origem e preserva os demais")
    func moveMarcadorGmail() async throws {
        let store = await store()
        let original = try #require(store.messages.first { $0.id == "m4" })
        let source = Self.pasta("Label_9", conta: "c2")
        let preserved = Self.pasta("VIP", conta: "c2")
        let target = Self.pasta("Projetos", conta: "c2")

        store.place(original, in: preserved, mode: .label)
        let labelled = try #require(store.messages.first { $0.id == "m4" })
        store.moveGmail(labelled, from: source, to: target)

        let updated = try #require(store.messages.first { $0.id == "m4" })
        #expect(updated.folderIDs == [preserved.id, target.id])
        #expect(updated.bucket == .archived)
    }

    @Test("Desfazer Mover para marcador Gmail repõe INBOX sem retirar marcador prévio")
    func undoMoveDestinationGmailKeepsExistingLabels() async throws {
        let inbox = Self.pasta("INBOX", conta: "c2", role: .inbox)
        let destination = Self.pasta("Projetos", conta: "c2")
        let preserved = Self.pasta("VIP", conta: "c2")
        let original = Self.mensagem(
            "mover-para", conta: "c2", pastas: ["INBOX", "Projetos", "VIP"], bucket: .today
        )
        let store = MailStore(source: FonteComPastas(
            contas: [Self.outraConta], mensagens: [original],
            pastas: [inbox, destination, preserved]
        ))
        await store.load()

        store.moveGmail(original, from: inbox, to: destination)
        let moved = try #require(store.messages.first)
        #expect(moved.folderIDs == [destination.id, preserved.id])
        #expect(moved.bucket == .archived)

        store.restoreFolderPlacements([
            .restoreGmailInbox(messageID: original.id, inbox: inbox)
        ])
        let restored = try #require(store.messages.first)
        #expect(restored.folderIDs == [destination.id, preserved.id, inbox.id])
        #expect(restored.bucket == .today)
    }

    @Test("Mudar a cor da caixa atualiza a conta na hora")
    func mudaCor() async throws {
        let store = await store()
        store.setAccountTint(
            accountID: "c1", lightHex: "#A92769", darkHex: "#F18BBE"
        )

        let account = try #require(store.account("c1"))
        #expect(account.tintLightHex == "#A92769")
        #expect(account.tintDarkHex == "#F18BBE")
    }

    // MARK: Sem conta, nada muda

    /// A promessa do app inteiro, aplicada às pastas: as fixtures não têm
    /// servidor, então não há pasta nenhuma e a barra é a do Marco 1.
    @Test("Sem conta conectada não há pasta nenhuma")
    func semContaNaoHaPasta() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(store.folders.isEmpty)
        for conta in store.accounts {
            #expect(store.folders(of: conta.id).isEmpty)
        }
    }
}

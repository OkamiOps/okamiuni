import AppKit
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("FolderSidebar")
@MainActor
struct SidebarTests {

    /// Os números que a barra escreve, contra o design. Literais de propósito:
    /// as asserções anteriores comparavam `count(for:)` com a mesma expressão
    /// que o define (`messages.filter { … }.count`) — verdadeiras por
    /// construção, e passavam com as quatro mensagens erradas que estavam nas
    /// fixtures. O que precisa bater é o número que se lê na tela.
    ///
    /// Desde o primeiro teste com contas reais: o dono quer NÃO LIDAS aqui,
    /// não o total — "Hoje" mostrava 44 (total) contra 6 não lidas no webmail.
    /// `FolderSidebar`/`SidebarRail` agora chamam `unreadCount(in:accountID:)`,
    /// e é isso que este teste passa a proxiar. Os literais não mudam porque
    /// as sete mensagens das fixtures nascem todas não lidas — `unreadCount`
    /// e `count(for:)` coincidem aqui por acaso, não por serem a mesma coisa;
    /// `bucketUnreadDiffersFromTotal` abaixo é quem prova a diferença.
    @Test("os contadores por caixa são os do design")
    @MainActor
    func counts() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(store.unreadCount(in: .today) == 3)
        #expect(store.unreadCount(in: .later) == 3)
        #expect(store.unreadCount(in: .all) == 7)
        #expect(store.unreadCount(in: .archived) == 1)
        // "Tudo" é uma visão, não um estado: nenhuma mensagem fica de fora dela.
        #expect(store.unreadCount(in: .today) + store.unreadCount(in: .later)
            + store.unreadCount(in: .archived) == store.unreadCount(in: .all))
    }

    /// O contador respeita o filtro de conta — é o que a barra mostra depois de
    /// clicar numa caixa. Design: a conta do site tem duas mensagens, uma em
    /// "Hoje" (o lead) e uma em "Depois" (a cobrança).
    @Test("filtrar por conta reduz os contadores de todas as caixas")
    @MainActor
    func countsFollowTheAccountFilter() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(account: "host")
        #expect(store.unreadCount(in: .all, accountID: store.selectedAccountID) == 2)
        #expect(store.unreadCount(in: .today, accountID: store.selectedAccountID) == 1)
        #expect(store.unreadCount(in: .later, accountID: store.selectedAccountID) == 1)
        #expect(store.unreadCount(in: .archived, accountID: store.selectedAccountID) == 0)
    }

    /// A prova de que a troca importa: com uma mensagem marcada como lida,
    /// `unreadCount` cai e `count(for:)` (o total) não se move. É a mutação
    /// vermelha do item 1 — se `FolderSidebar`/`SidebarRail` voltassem a
    /// chamar `count(for:)`, este teste continuaria vendo 3, não 2.
    @Test("uma mensagem lida sai do contador de não lidas, mas não do total")
    @MainActor
    func bucketUnreadDiffersFromTotal() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.setRead(true, for: "m1") // m1 é "Hoje", conta zoho.
        #expect(store.count(for: .today) == 3)
        #expect(store.unreadCount(in: .today) == 2)
    }

    /// `store.accounts.count == quantidade` é verdade mesmo se o desenho só
    /// mostrar a primeira conta (`prefix(1)`): o `store` está certo, quem
    /// mentiria é a `View`. Prova de verdade: renderizar duas listas de N
    /// contas idênticas exceto a **última**, que muda de cor entre elas, e
    /// exigir que a mudança apareça no bitmap. Se a `View` cortar para
    /// `prefix(1)` (ou qualquer corte que não alcance a última conta), a
    /// última linha nunca é desenhada e os dois bitmaps saem pixel a pixel
    /// iguais.
    private func accounts(_ quantidade: Int, lastTint: (light: String, dark: String)) -> [Account] {
        (0..<quantidade).map { i in
            let isLast = i == quantidade - 1
            return Account(
                id: "a\(i)", address: "conta\(i)@dominio\(i).com",
                displayName: "Conta \(i)", provider: .imap, host: "host\(i)",
                tintLightHex: isLast ? lastTint.light : "#3E6FA8",
                tintDarkHex: isLast ? lastTint.dark : "#7BA8D9"
            )
        }
    }

    @MainActor
    private func render(_ accounts: [Account]) async -> NSBitmapImageRep? {
        let store = MailStore(
            source: InMemoryMailSource(accounts: accounts, messages: [], agenda: [])
        )
        await store.load()
        // Alto o bastante para caber as 25 contas do maior caso sem rolar —
        // a rolagem cortaria a última linha do bitmap antes mesmo da mutação.
        return Render.bitmap(
            FolderSidebar(store: store),
            size: CGSize(width: FolderSidebar.expandedWidth, height: 2200),
            theme: .tinta
        )
    }

    @Test("a barra lista uma linha por conta, seja qual for a quantidade")
    @MainActor
    func oneRowPerAccount() async {
        for quantidade in [0, 1, 7, 25] {
            let contas = accounts(quantidade, lastTint: ("#3E6FA8", "#7BA8D9"))
            let store = MailStore(
                source: InMemoryMailSource(accounts: contas, messages: [], agenda: [])
            )
            await store.load()
            #expect(store.accounts.count == quantidade)
        }
    }

    @Test("cada conta desenha a própria linha, não só a primeira", arguments: [2, 7, 25])
    @MainActor
    func drawsARowForEveryAccount(quantidade: Int) async throws {
        let baseline = accounts(quantidade, lastTint: ("#3E6FA8", "#7BA8D9"))
        let changedLast = accounts(quantidade, lastTint: ("#C23B3B", "#E38585"))

        let a = try #require(await render(baseline))
        let b = try #require(await render(changedLast))

        #expect(a.pixelsWide == b.pixelsWide)
        #expect(a.pixelsHigh == b.pixelsHigh)
        #expect(
            a.pixelsDiffering(from: b) > 0,
            "mudar a cor só da última conta (de \(quantidade)) não mudou nada no desenho — a linha dela não está sendo desenhada"
        )
    }

    // MARK: A caixa Enviadas

    /// Um store com uma mensagem em cada caixa que este teste precisa: uma
    /// enviada (lida, como toda mensagem que a pessoa escreveu) e uma que
    /// chegou e não foi lida.
    @MainActor
    private func storeComEnviada() async -> MailStore {
        let conta = Account(
            id: "a0", address: "eu@meudominio.com.br", displayName: "Eu",
            provider: .imap, host: "meudominio",
            tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
        )
        let recebida = Message(
            id: "r1", accountID: "a0",
            from: Contact(name: "Marina Duarte", address: "marina@clientepremium.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: "Contrato", snippet: "Segue", body: [], tags: [],
            bucket: .today, isRead: false, summary: nil, detectedEvent: nil
        )
        let enviada = Message(
            id: "e1", accountID: "a0",
            from: Contact(name: "Eu", address: "eu@meudominio.com.br"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_100),
            subject: "Contrato", snippet: "Segue a versão final.", body: [], tags: [],
            bucket: .sent, isRead: true, summary: nil, detectedEvent: nil,
            to: [Contact(name: "Marina Duarte", address: "marina@clientepremium.com")]
        )
        let store = MailStore(
            source: InMemoryMailSource(accounts: [conta], messages: [recebida, enviada], agenda: [])
        )
        await store.load()
        return store
    }

    /// **O contador de Enviadas é o total, e não as não lidas.**
    ///
    /// Uma mensagem que você escreveu nasce lida: "não lidas" ali seria zero
    /// para sempre, e um número que nunca se move é ruído com cara de
    /// informação. É a única caixa em que a regra do dono ("quero não lidas")
    /// não se aplica, porque nela ela não diz nada.
    ///
    /// MUTAÇÃO QUE ISTO PEGA: `counter(for:store:)` voltar a chamar
    /// `unreadCount` para todas as caixas.
    @Test("Enviadas conta o total; as caixas do fluxo continuam contando não lidas")
    @MainActor
    func contadorDeEnviadas() async {
        let store = await storeComEnviada()
        #expect(FolderSidebar.counter(for: .sent, store: store) == 1)
        #expect(store.unreadCount(in: .sent) == 0)
        #expect(FolderSidebar.counter(for: .today, store: store) == 1)
        // E a enviada não infla "Tudo": ela não é triagem.
        #expect(FolderSidebar.counter(for: .all, store: store) == 1)
        #expect(store.count(for: .all) == 1)
    }

    /// A caixa nova é **desenhada**, e não só declarada: sem esta prova, um
    /// `ForEach` que percorresse `TriageBucket.triage` (as cinco do fluxo) em
    /// vez de `allCases` continuaria compilando, e Enviadas não apareceria em
    /// barra nenhuma.
    @Test("a barra desenha a caixa Enviadas — e a trilha também")
    @MainActor
    func aBarraDesenhaEnviadas() async throws {
        let comEnviada = await storeComEnviada()
        let store = comEnviada

        // O instrumento é o contador: com a caixa desenhada, mandar a única
        // enviada para a lixeira muda o que a barra escreve. Sem a linha
        // desenhada, os dois bitmaps saem idênticos.
        let antes = try #require(Render.bitmap(
            FolderSidebar(store: store),
            size: CGSize(width: FolderSidebar.expandedWidth, height: 420), theme: .tinta
        ))
        store.move(store.messages.first { $0.bucket == .sent }!, to: .trash)
        let depois = try #require(Render.bitmap(
            FolderSidebar(store: store),
            size: CGSize(width: FolderSidebar.expandedWidth, height: 420), theme: .tinta
        ))
        #expect(
            antes.pixelsDiffering(from: depois) > 0,
            "esvaziar Enviadas não mudou nada na barra — a caixa não está sendo desenhada"
        )

        let outro = await storeComEnviada()
        let trilhaAntes = try #require(Render.bitmap(
            SidebarRail(store: outro),
            size: CGSize(width: SidebarRail.width, height: 420), theme: .tinta
        ))
        outro.move(outro.messages.first { $0.bucket == .sent }!, to: .trash)
        let trilhaDepois = try #require(Render.bitmap(
            SidebarRail(store: outro),
            size: CGSize(width: SidebarRail.width, height: 420), theme: .tinta
        ))
        #expect(
            trilhaAntes.pixelsDiffering(from: trilhaDepois) > 0,
            "esvaziar Enviadas não mudou nada na trilha — a caixa não está sendo desenhada lá"
        )
    }

    @Test("a largura expandida é 236")
    @MainActor
    func expandedWidth() {
        #expect(FolderSidebar.expandedWidth == 236)
    }

    // MARK: As pastas do provedor

    /// Uma fonte com pastas — `InMemoryMailSource` não tem servidor nenhum e
    /// devolve `[]`, que é justamente o que mantém a barra sem conta idêntica à
    /// do Marco 1.
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

    @MainActor
    private func storeComPastas(segundaPasta: String = "Clientes/Faturas") async -> MailStore {
        let conta = Account(
            id: "c1", address: "marcos@okamiops.com", displayName: "Trabalho",
            provider: .imap, host: "okamiops",
            tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
        )
        let pastas = [
            MailFolder(
                id: "c1/INBOX", accountID: "c1", serverName: "INBOX",
                displayName: "INBOX", role: .inbox
            ),
            MailFolder(
                id: "c1/Clientes/Faturas", accountID: "c1", serverName: segundaPasta,
                displayName: segundaPasta, role: .other
            ),
        ]
        let store = MailStore(source: FonteComPastas(
            contas: [conta],
            mensagens: [
                Message(
                    id: "m1", accountID: "c1",
                    from: Contact(name: "Marina", address: "marina@clientepremium.com"),
                    receivedAt: Date(timeIntervalSince1970: 1_799_000_000),
                    subject: "Fatura", snippet: "Trecho", body: [], tags: [],
                    bucket: .archived, isRead: false, summary: nil, detectedEvent: nil,
                    folderIDs: ["c1/Clientes/Faturas"]
                )
            ],
            pastas: pastas
        ))
        await store.load()
        return store
    }

    @MainActor
    private func bitmap(_ store: MailStore) -> NSBitmapImageRep? {
        Render.bitmap(
            FolderSidebar(store: store),
            size: CGSize(width: FolderSidebar.expandedWidth, height: 520), theme: .tinta
        )
    }

    /// **A mutação:** apagar o `ForEach(store.folders(of:))` do corpo da barra
    /// faz os dois desenhos saírem idênticos — a conta abre e não mostra pasta
    /// nenhuma, que é exatamente a queixa do dono.
    ///
    /// O instrumento é o **nome de uma pasta**, e não o abrir e fechar: a seta
    /// muda de glifo ao abrir, então "recolhida contra aberta" acusaria
    /// diferença mesmo com as linhas de pasta apagadas — o teste passaria pela
    /// razão errada. Duas barras igualmente abertas, diferindo só no nome de uma
    /// pasta, não têm outra explicação possível.
    @Test("a conta aberta desenha as pastas do provedor")
    @MainActor
    func aContaAbertaDesenhaAsPastas() async throws {
        let umNome = await storeComPastas(segundaPasta: "Clientes/Faturas")
        umNome.toggleFolders(of: "c1")
        let outroNome = await storeComPastas(segundaPasta: "Fornecedores/Contratos")
        outroNome.toggleFolders(of: "c1")

        let a = try #require(bitmap(umNome))
        let b = try #require(bitmap(outroNome))
        #expect(
            a.pixelsDiffering(from: b) > 0,
            "trocar o nome de uma pasta não mudou nada na barra — as pastas não estão sendo desenhadas"
        )
    }

    /// **A mutação:** desenhar a seta sempre (tirar o `if !pastas.isEmpty`) faz
    /// a barra do Marco 1 ganhar uma seta ao lado de cada conta, e o retrato
    /// deixa de ser idêntico.
    @Test("sem pasta nenhuma, a barra é a do Marco 1 — até o pixel")
    @MainActor
    func semPastaAABarraEhADeSempre() async throws {
        let comFixtures = MailStore(source: InMemoryMailSource.fixtures)
        await comFixtures.load()
        let semPastas = try #require(bitmap(comFixtures))

        // O mesmo store, com as pastas "abertas": sem pasta nenhuma para
        // desenhar, abrir não pode mudar um pixel.
        for conta in comFixtures.accounts { comFixtures.toggleFolders(of: conta.id) }
        let aindaSemPastas = try #require(bitmap(comFixtures))
        #expect(semPastas.pixelsDiffering(from: aindaSemPastas) == 0)
    }

    /// **A seta com presença (M3-21).** O dono quase não a viu: 9pt de corpo,
    /// tinta `ink4` e um alvo de 10 pontos.
    ///
    /// Os três números estão travados aqui porque presença é comportamento —
    /// e o desenho está travado logo abaixo, no bitmap.
    @Test("a seta tem o corpo, a tinta e o alvo do idioma da base")
    func aSetaTemPresenca() {
        #expect(FolderSidebar.chevronSize == 11)
        #expect(FolderSidebar.chevronTargetWidth == 18)
        #expect(FolderSidebar.chevronTargetHeight == 24)
        // O alvo cabe na linha da conta, que mede 32.
        #expect(FolderSidebar.chevronTargetHeight <= 32)
    }

    /// A seta continua sendo **a seta**: aberta e fechada desenham diferente,
    /// e é o glifo que muda — não o resto da linha.
    @Test("aberta e fechada, a seta troca de glifo")
    @MainActor
    func aSetaTrocaDeGlifo() async throws {
        let fechada = await storeComPastas(segundaPasta: "Clientes/Faturas")
        let aberta = await storeComPastas(segundaPasta: "Clientes/Faturas")
        aberta.toggleFolders(of: "c1")
        let a = try #require(bitmap(fechada))
        let b = try #require(bitmap(aberta))
        #expect(a.pixelsDiffering(from: b) > 0)
    }
}
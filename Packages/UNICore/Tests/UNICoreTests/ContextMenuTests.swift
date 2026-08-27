import Foundation
import Testing
@testable import UNICore

/// O conteúdo dos menus de contexto é **dado**, e é aqui que ele se prova.
///
/// O `NSMenu` que o `contextMenu` do SwiftUI monta não aparece em renderização
/// fora da tela — e abrir menu de verdade exigiria clicar, que é a coisa que
/// este projeto não faz. Então a prova de "«Marcar como não lida» só aparece em
/// mensagem lida" mora nos itens, não nos pixels.
@Suite("Menus de contexto")
struct ContextMenuTests {

    // MARK: Ajudantes

    private func message(
        id: String = "m1",
        subject: String = "Revisão do contrato",
        address: String = "marina@clientepremium.com",
        bucket: TriageBucket = .today,
        isRead: Bool = false,
        body: [String] = ["Primeiro", "Segundo"],
        to: [Contact] = [],
        cc: [Contact] = []
    ) -> Message {
        Message(
            id: id, accountID: "zoho",
            from: Contact(name: "Marina Duarte", address: address),
            receivedAt: Fixtures.today, subject: subject,
            snippet: "trecho", body: body, tags: [],
            bucket: bucket, isRead: isRead, summary: nil, detectedEvent: nil,
            to: to, cc: cc
        )
    }

    private static let eu = Contact(name: "Ricardo", address: "ricardo@empresa.com")
    private static let outro = Contact(name: "Jurídico", address: "juridico@cliente.com")

    // MARK: - Estado de leitura no rótulo

    @Test("mensagem não lida oferece «Marcar como lida», e não o contrário")
    func unreadOffersMarkRead() {
        let entries = ContextMenus.messageRow(message(isRead: false))

        #expect(entries.titles.contains("Marcar como lida"))
        #expect(!entries.titles.contains("Marcar como não lida"))
        #expect(entries.commands.contains(.setRead(messageID: "m1", isRead: true)))
    }

    @Test("mensagem lida oferece «Marcar como não lida», e não o contrário")
    func readOffersMarkUnread() {
        let entries = ContextMenus.messageRow(message(isRead: true))

        #expect(entries.titles.contains("Marcar como não lida"))
        #expect(!entries.titles.contains("Marcar como lida"))
        #expect(entries.commands.contains(.setRead(messageID: "m1", isRead: false)))
    }

    @Test("o leitor sinaliza o mesmo estado que a linha da lista")
    func readerAgreesWithRow() {
        let read = message(isRead: true)
        #expect(ContextMenus.reader(read).titles.contains("Marcar como não lida"))
        #expect(ContextMenus.reader(message(isRead: false)).titles.contains("Marcar como lida"))
    }

    // MARK: - Submenu de triagem

    @Test("«Mover para» não oferece a caixa em que a mensagem já está")
    func moveSkipsCurrentBucket() {
        let entries = ContextMenus.messageRow(message(bucket: .later))
        let targets = entries.submenuCommands("Mover para")

        #expect(targets == [
            .move(messageID: "m1", to: .today),
            .move(messageID: "m1", to: .archived),
        ])
        // "Tudo" é visão, não estado de triagem: mover para lá não quer dizer
        // nada, e `move(_:to:.all)` deixaria a mensagem numa caixa que não
        // existe como destino.
        #expect(!targets.contains(.move(messageID: "m1", to: .all)))
    }

    /// Ele deixou de sumir na Task AR. A lista de ações de topo tem de ser a
    /// mesma em toda linha: sumir faria o menu dançar de mensagem para
    /// mensagem justamente na ação de uso mais frequente. Apagado com
    /// explicação diz a mesma coisa sem mexer no menu.
    @Test("arquivada mostra «Arquivar» apagado, com o motivo — nunca mudo, nunca ausente")
    func archivedShowsArchiveDisabled() {
        for entries in [
            ContextMenus.reader(message(bucket: .archived)),
            ContextMenus.messageRow(message(bucket: .archived)),
        ] {
            let item = entries.item("Arquivar")
            #expect(item?.isEnabled == false)
            #expect(item?.help == "Esta mensagem já está em Arquivado")
        }
        for entries in [
            ContextMenus.reader(message(bucket: .today)),
            ContextMenus.messageRow(message(bucket: .today)),
        ] {
            let item = entries.item("Arquivar")
            #expect(item?.isEnabled == true)
            #expect(item?.command == .move(messageID: "m1", to: .archived))
            #expect(item?.shortcut?.label == "⌘E")
        }
    }

    /// Promovido, não movido: quem já sabia o caminho antigo não o perde.
    @Test("«Arquivar» no topo não tirou Arquivado de «Mover para»")
    func archiveIsStillInTheSubmenu() {
        let targets = ContextMenus.messageRow(message()).submenuCommands("Mover para")
        #expect(targets.contains(.move(messageID: "m1", to: .archived)))
    }

    // MARK: - Copiar

    @Test("copiar leva o endereço e o assunto que a mensagem traz")
    func copyCarriesTheRealText() {
        let entries = ContextMenus.messageRow(
            message(subject: "Revisão do contrato", address: "marina@clientepremium.com")
        )

        #expect(entries.commands.contains(.copy("marina@clientepremium.com")))
        #expect(entries.commands.contains(.copy("Revisão do contrato")))
    }

    @Test("assunto vazio não vira item de copiar")
    func emptySubjectHasNoItem() {
        let entries = ContextMenus.messageRow(message(subject: ""))

        #expect(!entries.titles.contains("Copiar assunto"))
        #expect(entries.titles.contains("Copiar endereço do remetente"))
    }

    @Test("o corpo copiado é o texto da mensagem, com linha em branco entre parágrafos")
    func bodyTextJoinsParagraphs() {
        let entries = ContextMenus.reader(message(body: ["Primeiro", "Segundo"]))

        #expect(entries.commands.contains(.copy("Primeiro\n\nSegundo")))
    }

    // MARK: - O que ficou de fora

    /// Cada um destes falharia como botão mudo se entrasse. A lista está no
    /// relatório da tarefa, com o motivo medido no código de cada um.
    @Test("o menu do leitor não traz ação sem caminho neste marco")
    func readerHasNoDeadItems() {
        let titles = ContextMenus.reader(message()).titles

        // O botão do cartão de resumo existe (`ReaderPane.addToAgendaButton`),
        // mas o menu não tem onde mostrar a confirmação com "Desfazer" que
        // ele devolve — ver o comentário de `ContextMenus.reader`.
        #expect(!titles.contains("Colocar na agenda"))
        // `Message.body` é `[String]` sem marcação: não há link a acertar.
        #expect(!titles.contains("Copiar link"))
    }

    @Test("nenhum menu abre, fecha ou repete separador")
    func separatorsAreTidy() {
        let account = Fixtures.accounts[0]
        let menus: [[ContextMenuEntry]] = [
            ContextMenus.messageRow(message()),
            ContextMenus.messageRow(message(subject: "", address: "", bucket: .archived, isRead: true)),
            ContextMenus.reader(message()),
            ContextMenus.reader(message(subject: "", address: "", bucket: .archived, isRead: true)),
            ContextMenus.accountRow(account, isFiltered: false, unread: 0),
            ContextMenus.accountRow(account, isFiltered: true, unread: 3),
            ContextMenus.agendaBlock(
                Fixtures.agenda[0],
                detail: Fixtures.eventDefault,
                date: nil,
                originMessageID: nil
            ),
        ]

        for menu in menus {
            #expect(menu.first?.isSeparator != true)
            #expect(menu.last?.isSeparator != true)
            for pair in zip(menu, menu.dropFirst()) {
                #expect(!(pair.0.isSeparator && pair.1.isSeparator))
            }
        }
    }

    // MARK: - Barra lateral

    @Test("caixa sem não lidas não oferece «Marcar tudo como lido»")
    func nothingToMarkMeansNoItem() {
        #expect(ContextMenus.bucketRow(.today, unread: 0, accountID: nil).isEmpty)

        let entries = ContextMenus.bucketRow(.today, unread: 4, accountID: "zoho")
        #expect(entries.commands == [.markAllRead(bucket: .today, accountID: "zoho")])
    }

    @Test("o rótulo do filtro segue o estado da conta")
    func filterLabelFollowsState() {
        let account = Fixtures.accounts[0]

        let idle = ContextMenus.accountRow(account, isFiltered: false, unread: 0)
        #expect(idle.titles.first == "Filtrar só esta conta")
        #expect(idle.commands.contains(.filterAccount(accountID: account.id)))

        let filtered = ContextMenus.accountRow(account, isFiltered: true, unread: 0)
        #expect(filtered.titles.first == "Limpar filtro")
        #expect(filtered.commands.contains(.clearAccountFilter))
    }

    @Test("copiar o endereço da conta usa o endereço dela, não o id nem o host")
    func accountCopyUsesAddress() {
        // Qualquer provedor: a asserção é sobre o campo, não sobre estas contas.
        for account in Fixtures.accounts {
            let entries = ContextMenus.accountRow(account, isFiltered: false, unread: 0)
            #expect(entries.commands.contains(.copy(account.address)))
            #expect(!entries.commands.contains(.copy(account.id)))
        }
    }

    // MARK: - Compromisso

    @Test("sem link de reunião o item de copiar link não entra")
    func noLinkNoItem() {
        let item = Fixtures.agenda[0]
        let withoutLink = ContextMenus.agendaBlock(
            item, detail: Fixtures.eventDefault, date: nil, originMessageID: nil
        )
        #expect(!withoutLink.titles.contains("Copiar link da reunião"))

        let detail = Fixtures.eventDetail(for: "Standup")
        let withLink = ContextMenus.agendaBlock(
            item, detail: detail, date: nil, originMessageID: nil
        )
        #expect(withLink.commands.contains(.copy("https://meet.google.com/kzq-mfrp-tdy")))
    }

    @Test("sem mensagem casada não há «Ir para o email de origem»")
    func noOriginNoItem() {
        let item = Fixtures.agenda[0]
        #expect(!ContextMenus.agendaBlock(
            item, detail: Fixtures.eventDefault, date: nil, originMessageID: nil
        ).titles.contains("Ir para o email de origem"))

        #expect(ContextMenus.agendaBlock(
            item, detail: Fixtures.eventDefault, date: nil, originMessageID: "m4"
        ).commands.contains(.revealMessage(messageID: "m4")))
    }

    @Test("a origem sai da linha de email do histórico, casada pelo assunto")
    func originComesFromTheThread() {
        let standup = Fixtures.eventDetail(for: "Standup")
        // A linha é `EventThreadEntry(kind: .email, what: "Notas do standup + …")`,
        // que é o assunto de m4.
        #expect(ContextMenus.originMessageID(for: standup, in: Fixtures.messages) == "m4")

        let oneOnOne = Fixtures.eventDetail(for: "1:1 Marina")
        #expect(ContextMenus.originMessageID(for: oneOnOne, in: Fixtures.messages) == "m1")

        // Sem histórico não há origem.
        #expect(ContextMenus.originMessageID(for: Fixtures.eventDefault, in: Fixtures.messages) == nil)
        // Histórico só de sistema/IA também não: a origem é o email.
        let weekly = Fixtures.eventDetail(for: "Revisão semanal")
        #expect(weekly.thread.isEmpty)
        #expect(ContextMenus.originMessageID(for: weekly, in: Fixtures.messages) == nil)
    }

    @Test("o convite copiado traz título, horário, local, link e participantes")
    func inviteTextIsComplete() {
        let item = AgendaItem(
            id: "e1", title: "Standup produto",
            startMinute: 570, endMinute: 600, accountID: "zoho"
        )
        let detail = Fixtures.eventDetail(for: "Standup")

        let text = ContextMenus.inviteText(item, detail: detail, date: Fixtures.today)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines[0] == "Standup produto")
        #expect(lines[1] == "Terça, 25 de agosto · 09:30 – 10:00")
        #expect(lines[2] == "Google Meet · sala do time")
        #expect(lines[3] == "https://meet.google.com/kzq-mfrp-tdy")
        #expect(lines[5] == "Participantes:")
        // O organizador vem primeiro, como `guests(me:)` monta.
        #expect(lines[6] == "· Equipe Produto <produto@empresa.com> — organizador")
        #expect(lines.contains("· Pedro Alencar <pedro@empresa.com> — obrigatório"))
        // Ninguém ganha "· você": o convite é o texto do compromisso, não a
        // visão de uma caixa. Nada de conta fixa aqui.
        #expect(!text.contains("· você"))
    }

    @Test("sem data o convite escreve só o horário, não uma data inventada")
    func inviteWithoutDate() {
        let item = AgendaItem(
            id: "e1", title: "Foco", startMinute: 600, endMinute: 690, accountID: "zoho"
        )
        let text = ContextMenus.inviteText(item, detail: Fixtures.eventDefault, date: nil)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines[0] == "Foco")
        #expect(lines[1] == "10:00 – 11:30")
    }

    // MARK: - Atalho

    @Test("todo atalho escrito no menu é um atalho que o app de fato escuta")
    func onlyRealShortcutsAreShown() {
        let all = ContextMenus.messageRow(message()) + ContextMenus.reader(message())
        var shortcuts: [String: MenuShortcut] = [:]
        for case .item(let item) in all {
            if let shortcut = item.shortcut { shortcuts[item.title] = shortcut }
        }

        #expect(shortcuts == [
            "Responder": MenuShortcut(key: "r"),
            "Responder a todos": MenuShortcut(key: "r", modifiers: [.command, .shift]),
            "Encaminhar": MenuShortcut(key: "f", modifiers: [.command, .shift]),
            "Arquivar": MenuShortcut(key: "e"),
            "Marcar como lida": MenuShortcut(key: "u", modifiers: [.command, .shift]),
        ])
        #expect(shortcuts["Responder"]?.label == "⌘R")
        #expect(shortcuts["Responder a todos"]?.label == "⇧⌘R")
        #expect(shortcuts["Encaminhar"]?.label == "⇧⌘F")
        #expect(shortcuts["Arquivar"]?.label == "⌘E")
        #expect(shortcuts["Marcar como lida"]?.label == "⇧⌘U")
    }

    /// O adiar. É o único item do submenu com atalho — os outros não têm um, e
    /// escrever equivalente que ninguém escuta seria o botão mudo em tipografia.
    @Test("«Depois» leva ⇧⌘D dentro de «Mover para», e só ele")
    func onlyLaterCarriesAShortcutInsideTheSubmenu() {
        var comAtalho: [String: String] = [:]
        for case .submenu(_, let items) in ContextMenus.messageRow(message()) {
            for item in items where item.shortcut != nil {
                comAtalho[item.title] = item.shortcut?.label
            }
        }
        #expect(comAtalho == ["Depois": "⇧⌘D"])
    }

    // MARK: - Encaminhar

    /// A dívida da revisão AG: enquanto a janela 03 não sabia encaminhar, o
    /// item ficava fora. Agora ela sabe, e ele entra aceso nas duas superfícies
    /// — inclusive na mensagem que não tem mais ninguém além do remetente, que
    /// é justamente onde "Responder a todos" apaga.
    @Test("«Encaminhar» entra aceso na linha e no leitor, sem depender de destinatário")
    func forwardIsAlwaysThere() {
        for entries in [
            ContextMenus.messageRow(message()), ContextMenus.reader(message()),
        ] {
            let item = entries.item("Encaminhar")
            #expect(item?.isEnabled == true)
            #expect(item?.command == .forward(messageID: "m1"))
        }
    }

    // MARK: - Responder a todos

    @Test("«Responder a todos» acende quando há mais alguém além do remetente")
    func replyAllEnabledWithOthers() {
        let entries = ContextMenus.messageRow(
            message(to: [Self.eu], cc: [Self.outro]),
            accountAddress: Self.eu.address
        )
        let item = entries.item("Responder a todos")

        #expect(item?.isEnabled == true)
        #expect(item?.command == .replyAll(messageID: "m1"))
        #expect(item?.help == "Responder ao remetente e a mais 1 pessoa")
    }

    @Test("sem `to` nem `cc` o item aparece apagado — e diz por quê, nunca mudo")
    func replyAllDisabledWhenAlone() {
        for entries in [
            ContextMenus.messageRow(message(), accountAddress: Self.eu.address),
            ContextMenus.reader(message(), accountAddress: Self.eu.address),
        ] {
            let item = entries.item("Responder a todos")
            // Ele **está** no menu: some seria mentir por omissão num item que
            // Gmail e Outlook sempre mostram.
            #expect(item != nil)
            #expect(item?.isEnabled == false)
            #expect(item?.help == "Esta mensagem não tem mais ninguém além do remetente")
        }
    }

    @Test("uma mensagem só para a própria conta não conta como «todos»")
    func replyAllIgnoresOwnAddress() {
        let entries = ContextMenus.messageRow(
            message(to: [Self.eu]), accountAddress: Self.eu.address
        )
        #expect(entries.item("Responder a todos")?.isEnabled == false)
    }
}

extension Array where Element == ContextMenuEntry {
    /// O item de primeiro nível com este rótulo. Existe para os testes lerem o
    /// menu como quem o lê na tela — e para distinguir "está apagado" de
    /// "não está lá", que é a diferença que a Task AR passou a exigir.
    func item(_ title: String) -> ContextMenuItem? {
        for case .item(let item) in self where item.title == title { return item }
        return nil
    }
}

/// As duas metades novas do `MailStore`. "Marcar como não lida" é a única ação
/// dos menus que não tinha caminho nenhum antes.
@Suite("Estado de leitura no MailStore")
@MainActor
struct ReadStateTests {

    private func loadedStore() async -> MailStore {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        return store
    }

    @Test("marcar como não lida desfaz a leitura da mensagem aberta")
    func markUnread() async throws {
        let store = await loadedStore()
        store.select(bucket: .all)
        // `load()` aponta o leitor para a primeira mensagem sem marcá-la lida;
        // quem marca é `select(message:)`. Então a leitura entra por aqui.
        let opened = try #require(store.messages.first { !$0.isRead })
        store.select(message: opened.id)
        #expect(store.selectedMessage?.isRead == true)

        store.setRead(false, for: opened.id)

        let after = try #require(store.messages.first { $0.id == opened.id })
        #expect(!after.isRead)
        // A mensagem continua aberta: no macOS marcar a aberta como não lida
        // não a tira da tela.
        #expect(store.selectedMessageID == opened.id)
        // E o dia e as sugestões sobrevivem à reconstrução.
        #expect(after.dayOffset == opened.dayOffset)
        #expect(after.replyHints == opened.replyHints)
    }

    @Test("marcar tudo como lido zera a caixa, e só ela")
    func markAllReadInBucket() async throws {
        let store = await loadedStore()
        #expect(store.unreadCount(in: .today) > 0)
        let elsewhereBefore = store.messages.filter { !$0.isRead && $0.bucket != .today }.count
        #expect(elsewhereBefore > 0)

        store.markAllRead(in: .today)

        #expect(store.unreadCount(in: .today) == 0)
        #expect(store.messages.filter { !$0.isRead && $0.bucket != .today }.count == elsewhereBefore)
    }

    @Test("marcar tudo como lido numa conta não toca nas outras")
    func markAllReadInAccount() async throws {
        let store = await loadedStore()
        let target = try #require(
            store.accounts.first { store.unreadCount(in: .all, accountID: $0.id) > 0 }
        )
        let others = store.accounts.filter { $0.id != target.id }
        let before = others.map { store.unreadCount(in: .all, accountID: $0.id) }

        store.markAllRead(in: .all, accountID: target.id)

        #expect(store.unreadCount(in: .all, accountID: target.id) == 0)
        #expect(others.map { store.unreadCount(in: .all, accountID: $0.id) } == before)
    }

    @Test("marcar tudo como lido ignora a busca")
    func markAllReadIgnoresQuery() async throws {
        let store = await loadedStore()
        store.select(bucket: .all)
        store.query = "zzzz-nao-casa-com-nada"
        #expect(store.visibleMessages.isEmpty)

        store.markAllRead(in: .all)

        // Se olhasse `visibleMessages`, nada teria mudado — e o contador da
        // barra lateral, que não olha a busca, seguiria acusando não lidas.
        #expect(store.unreadCount(in: .all) == 0)
    }

    /// "Ir para o email de origem" tem de deixar a mensagem **na lista**, não
    /// só no leitor. Cada filtro abaixo a esconderia, e cada um é desfeito
    /// separadamente para não jogar fora o recorte que ainda serve.
    @Test("ir para uma mensagem desfaz a caixa, o filtro de conta e a busca que a escondem")
    func revealDefeatsEveryFilter() async throws {
        let store = await loadedStore()
        // Uma mensagem que a caixa aberta não mostra, de uma conta que não é a
        // filtrada, e fora do que a busca casa.
        let target = try #require(store.messages.first { $0.bucket == .later })
        let otherAccount = try #require(
            store.accounts.first { $0.id != target.accountID }
        )

        store.select(bucket: .today)
        store.select(account: otherAccount.id)
        store.query = "zzzz-nao-casa-com-nada"
        #expect(!store.visibleMessages.contains { $0.id == target.id })

        store.reveal(target.id)

        #expect(store.selectedMessageID == target.id)
        #expect(store.visibleMessages.contains { $0.id == target.id })
        #expect(store.query.isEmpty)
        #expect(store.selectedAccountID == nil)
        #expect(store.bucket == .later)
    }

    @Test("ir para uma mensagem preserva o recorte que já a mostrava")
    func revealKeepsUsefulFilters() async throws {
        let store = await loadedStore()
        store.select(bucket: .all)
        let target = try #require(store.messages.first)
        store.select(account: target.accountID)
        // Uma busca que **casa** com ela não precisa ser desfeita.
        store.query = target.subject
        #expect(store.visibleMessages.contains { $0.id == target.id })

        store.reveal(target.id)

        #expect(store.selectedAccountID == target.accountID)
        #expect(store.query == target.subject)
        #expect(store.bucket == .all)
    }

    @Test("ir para um id que não existe não mexe em nada")
    func revealIgnoresUnknownID() async throws {
        let store = await loadedStore()
        store.select(bucket: .later)
        store.query = "contrato"
        let before = (store.bucket, store.query, store.selectedMessageID)

        store.reveal("nao-existe")

        #expect(store.bucket == before.0)
        #expect(store.query == before.1)
        #expect(store.selectedMessageID == before.2)
    }

    @Test("a contagem de não lidas respeita caixa e conta")
    func unreadCountScopes() async throws {
        let store = await loadedStore()
        let total = store.unreadCount(in: .all)
        let byAccount = store.accounts.reduce(0) { $0 + store.unreadCount(in: .all, accountID: $1.id) }
        #expect(total == byAccount)

        let byBucket = TriageBucket.allCases
            .filter { $0 != .all }
            .reduce(0) { $0 + store.unreadCount(in: $1) }
        #expect(total == byBucket)
    }
}

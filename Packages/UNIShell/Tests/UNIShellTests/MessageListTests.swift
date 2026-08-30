import AppKit
import SwiftUI
import Testing
import Foundation
import UNICore
import UNIDesign
@testable import UNIShell

@Suite("MessageList")
struct MessageListTests {

    // MARK: - Filtros de categoria em Hoje

    @Test("a trilha de Hoje oferece categorias estáveis, inclusive Todos")
    @MainActor
    func todayCategoryFilters() {
        #expect(InboxCategoryFilter.allCases.map(\.label) == [
            "Todos", "Principal", "Transações", "Atualizações", "Promoções", "Social",
        ])
        #expect(InboxCategoryFilter.allCases.map(\.symbol) == [
            "tray.full", "person.crop.circle", "creditcard", "bell", "tag", "person.2",
        ])
        #expect(InboxCategoryFilter.all.category == nil)
        #expect(InboxCategoryFilter.primary.category == .primary)
        #expect(InboxCategoryFilter.transactions.category == .transactions)
        #expect(InboxCategoryFilter.updates.category == .updates)
        #expect(InboxCategoryFilter.promotions.category == .promotions)
        #expect(InboxCategoryFilter.social.category == .social)
    }

    @Test("somente Hoje amplia o cabeçalho para a trilha de categorias")
    @MainActor
    func categoryHeaderHeightIsExclusiveToToday() {
        #expect(MessageList.headerHeight(for: .today) == 118)
        for bucket in [TriageBucket.later, .all, .archived, .trash, .sent] {
            #expect(MessageList.headerHeight(for: bucket) == 74)
        }
    }

    /// Uma mensagem qualquer, sem depender das fixtures, para provar regra de
    /// agrupamento em vez de conferir dado.
    private func message(_ id: String, dayOffset: Int, at receivedAt: Date = .now) -> Message {
        Message(
            id: id, accountID: "a",
            from: Contact(name: "Quem", address: "quem@exemplo.com"),
            receivedAt: receivedAt, subject: "Assunto", snippet: "Trecho",
            body: [], tags: [], bucket: .today, isRead: false,
            summary: nil, detectedEvent: nil, dayOffset: dayOffset
        )
    }

    // MARK: - O rótulo sai do dado, não do relógio

    @Test("o grupo de hoje se chama 'Hoje'")
    func todayLabel() {
        let groups = MessageGroup.build(from: [message("a", dayOffset: 0)])
        #expect(groups.first?.label == "Hoje")
    }

    @Test("o grupo de ontem se chama 'Ontem'")
    func yesterdayLabel() {
        let groups = MessageGroup.build(from: [message("a", dayOffset: -1)])
        #expect(groups.first?.label == "Ontem")
    }

    /// O defeito que o dono do projeto viu: a janela escrevia "25 DE AGO." onde
    /// o design escreve "Hoje".
    ///
    /// A mensagem aqui chegou em 2019 e mesmo assim é do grupo "Hoje", porque é
    /// o que ela declara. Se o rótulo voltar a sair de `isDateInToday`, esta
    /// data cai em "13 de nov." e o teste falha — em qualquer dia do ano, o que
    /// a versão anterior deste teste não conseguia (ela passava por acaso, por
    /// usar `.now`).
    @Test("o rótulo vem do dia declarado, não da data nem do relógio da máquina")
    func labelIgnoresTheClock() throws {
        var parts = DateComponents()
        parts.year = 2019; parts.month = 11; parts.day = 13; parts.hour = 8
        let longAgo = try #require(Calendar(identifier: .gregorian).date(from: parts))

        let groups = MessageGroup.build(from: [message("a", dayOffset: 0, at: longAgo)])
        #expect(groups.count == 1)
        #expect(groups.first?.label == "Hoje")
    }

    @Test("um dia sem nome cai na data, e não em 'Hoje' por descuido")
    func olderDayFallsBackToDate() throws {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 8; parts.day = 19; parts.hour = 8
        let older = try #require(Calendar(identifier: .gregorian).date(from: parts))

        let groups = MessageGroup.build(from: [message("a", dayOffset: -6, at: older)])
        let label = try #require(groups.first?.label)
        #expect(label != "Hoje")
        #expect(label != "Ontem")
        #expect(label.isEmpty == false)
    }

    // MARK: - Agrupamento

    @Test("mensagens do mesmo dia entram no mesmo grupo, na ordem que vieram")
    func sameDayStaysTogether() throws {
        let groups = MessageGroup.build(from: [
            message("a", dayOffset: 0),
            message("b", dayOffset: 0),
            message("c", dayOffset: -1),
        ])
        #expect(groups.count == 2)
        #expect(groups.map(\.label) == ["Hoje", "Ontem"])
        #expect(groups[0].messages.map(\.id) == ["a", "b"])
        #expect(groups[1].messages.map(\.id) == ["c"])
    }

    @Test("dois dias diferentes nunca caem no mesmo grupo")
    func differentDaysSplit() {
        let groups = MessageGroup.build(from: [
            message("a", dayOffset: 0),
            message("c", dayOffset: -1),
        ])
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.messages.count == 1 })
    }

    @Test("lista vazia não gera grupo vazio")
    func noEmptyGroups() {
        #expect(MessageGroup.build(from: []).isEmpty)
    }

    @Test("nenhuma mensagem se perde no agrupamento")
    @MainActor
    func nothingIsLost() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)

        let groups = MessageGroup.build(from: store.visibleMessages)
        #expect(groups.isEmpty == false)
        #expect(groups.flatMap(\.messages).count == store.visibleMessages.count)
        #expect(Set(groups.flatMap(\.messages).map(\.id)).count == store.visibleMessages.count)
    }

    // MARK: - O que a lista mostra, contra o design

    /// Design, `const MSGS` (linha 1547): sete mensagens em dois dias — três de
    /// hoje (m1 09:42, m4 08:40, m2 08:15) e quatro de ontem (m6, m3, m7, m5).
    @Test("a caixa Tudo mostra as sete do design em dois grupos")
    @MainActor
    func allBucketMatchesDesign() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)

        #expect(store.visibleMessages.count == 7)

        let groups = MessageGroup.build(from: store.visibleMessages)
        #expect(groups.map(\.label) == ["Hoje", "Ontem"])
        // Dentro do dia, mais recente primeiro — `visibleMessages` ordena por
        // `receivedAt`. Ontem: 19:22, 14:20, 11:07, 06:00.
        #expect(groups[0].messages.map(\.id) == ["m1", "m4", "m2"])
        #expect(groups[1].messages.map(\.id) == ["m3", "m5", "m6", "m7"])
    }

    /// A caixa que a janela abre. Hoje é data de recebimento, não sinônimo de
    /// Inbox: `m6` continua acessível em Tudo, mas não entra neste recorte por
    /// ter chegado ontem.
    @Test("a caixa Hoje abre somente com as duas mensagens recebidas hoje")
    @MainActor
    func todayBucketMatchesDesign() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        #expect(store.bucket == .today)
        #expect(store.visibleMessages.map(\.id) == ["m1", "m4"])

        let groups = MessageGroup.build(from: store.visibleMessages)
        #expect(groups.map(\.label) == ["Hoje"])
        #expect(groups[0].messages.map(\.id) == ["m1", "m4"])
    }

    /// `account?.host == "hostinger"` provado por leitura de dado não prova o
    /// que a linha desenha — trocar `account?.host` por `account?.id` em
    /// `MessageList.swift` continua batendo com essa asserção porque as duas
    /// propriedades existem, ambas em `Account`; só o texto na tela muda.
    ///
    /// Prova de verdade: uma conta com `id` ≠ `host`, renderizada duas vezes —
    /// uma vez com o `host` real, outra com um `host` diferente mas o mesmo
    /// `id`. Se a linha lê `account.host`, os dois desenhos do chip divergem;
    /// se lê `account.id` (a mutação), o `id` não mudou entre as duas rodadas
    /// e o desenho sai idêntico — pixel a pixel — mesmo o `host` tendo mudado.
    @MainActor
    private func renderChip(host: String) async -> NSBitmapImageRep? {
        let account = Account(
            id: "a", address: "conta@dominio.com", displayName: "Conta",
            provider: .imap, host: host, tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
        )
        let msg = message("m1", dayOffset: 0)
        let source = InMemoryMailSource(accounts: [account], messages: [msg], agenda: [])
        let store = MailStore(source: source)
        await store.load()
        store.select(bucket: .all)
        return Render.bitmap(
            MessageList(store: store), size: CGSize(width: MessageList.width, height: 200),
            theme: .tinta
        )
    }

    @Test("o chip da linha escreve o host da conta, e muda se o host mudar")
    @MainActor
    func rowChipShowsProviderName() async throws {
        let a = try #require(await renderChip(host: "hostinger"))
        let b = try #require(await renderChip(host: "algumoutroprovedor"))

        #expect(a.pixelsWide == b.pixelsWide)
        #expect(a.pixelsHigh == b.pixelsHigh)
        #expect(
            a.pixelsDiffering(from: b) > 0,
            "o chip não mudou quando só o host da conta mudou — a linha não está lendo account.host"
        )
    }

    // MARK: - Medidas e rótulos da moldura

    @Test("a largura da lista é a do design")
    @MainActor
    func width() {
        #expect(MessageList.width == 400)
    }

    @Test("o rótulo de contagem usa plural correto")
    @MainActor
    func pluralZero() {
        #expect(MessageList.messageCountLabel(0) == "0 mensagens")
    }

    @Test("singular para uma mensagem")
    @MainActor
    func pluralOne() {
        #expect(MessageList.messageCountLabel(1) == "1 mensagem")
    }

    @Test("plural para múltiplas mensagens")
    @MainActor
    func pluralMany() {
        #expect(MessageList.messageCountLabel(42) == "42 mensagens")
    }
}

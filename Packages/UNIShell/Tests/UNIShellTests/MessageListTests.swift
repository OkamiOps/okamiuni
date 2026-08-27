import Testing
import Foundation
import UNICore
@testable import UNIShell

@Suite("MessageList")
struct MessageListTests {

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

    /// A caixa que a janela abre. Design: `mailbox: 'hoje'` filtra por `bucket`,
    /// que é triagem — não por dia. Por isso `m6`, que chegou ontem, aparece
    /// aqui sob o cabeçalho "Ontem": duas mensagens em "Hoje", uma em "Ontem".
    @Test("a caixa Hoje abre com três mensagens em dois grupos")
    @MainActor
    func todayBucketMatchesDesign() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        #expect(store.bucket == .today)
        #expect(store.visibleMessages.map(\.id) == ["m1", "m4", "m6"])

        let groups = MessageGroup.build(from: store.visibleMessages)
        #expect(groups.map(\.label) == ["Hoje", "Ontem"])
        #expect(groups[0].messages.map(\.id) == ["m1", "m4"])
        #expect(groups[1].messages.map(\.id) == ["m6"])
    }

    @Test("o chip da linha escreve o nome do provedor, não a chave da conta")
    @MainActor
    func rowChipShowsProviderName() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        store.select(bucket: .all)

        let fromHostinger = try #require(store.visibleMessages.first { $0.accountID == "host" })
        let account = try #require(store.account(fromHostinger.accountID))
        #expect(account.host == "hostinger")
        #expect(account.id == "host")
    }

    // MARK: - Medidas e rótulos da moldura

    @Test("a largura da lista é a do design")
    @MainActor
    func width() {
        #expect(MessageList.width == 370)
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

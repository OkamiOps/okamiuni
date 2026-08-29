import Foundation
import Testing
@testable import UNICore

/// **O defeito do dono:** "Coloco o item no calendário e ao fechar e abrir o
/// OkamiUNI a agenda some."
///
/// Sumia mesmo. `MailStore.addToAgenda` acrescentava o compromisso à lista em
/// memória e mais nada — o comentário de `AgendaItem.calendarUID` já registrava
/// a dívida em voz alta ("a agenda ainda é de sessão; nada escreve em
/// `agenda_item`"). O retrato seguinte vinha da fonte, `apply(_:)` substituía a
/// lista inteira, e o compromisso ia junto. Fechar o app era só o caso mais
/// visível disso.
///
/// Aqui a porta é a de memória; a de disco tem os testes dela em `UNISync`.
/// Fechar e abrir o app é modelado do jeito honesto: **um `MailStore` novo**
/// sobre a mesma porta, que é exatamente o que o próximo lançamento monta.
@Suite("A agenda sobrevive a fechar e abrir")
@MainActor
struct AgendaSurvivesRestartTests {

    private static let calendario = Calendar(identifier: .gregorian)
    private static let hoje = Fixtures.today
    private static let amanha = calendario.date(byAdding: .day, value: 1, to: hoje)!

    private static let conta = Account(
        id: "zoho", address: "ricardo@zoho.com", displayName: "Zoho",
        provider: .imap, host: "zoho", tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
    )

    /// A mensagem com um compromisso detectado: quinta, 27 de agosto, 15:00 —
    /// dois dias depois do "hoje" do protótipo.
    private static func mensagem() -> Message {
        let inicio = calendario.date(
            byAdding: .day, value: 2,
            to: calendario.date(bySettingHour: 15, minute: 0, second: 0, of: hoje)!
        )!
        return Message(
            id: "m1", accountID: "zoho",
            from: Contact(name: "Favini", address: "favini@vantion.com.br"),
            receivedAt: hoje, subject: "Call de contrato", snippet: "trecho",
            body: ["texto"], tags: [], bucket: .today, isRead: true,
            summary: "resumo",
            detectedEvent: DetectedEvent(
                label: "Call de contrato · qui 27, 15:00", start: inicio, duration: 30 * 60
            )
        )
    }

    /// Uma abertura do app: `MailStore` novo, mesma porta, mesmo "hoje".
    private func abertura(
        porta: AgendaEmMemoria, hoje: Date = AgendaSurvivesRestartTests.hoje,
        fonte: InMemoryMailSource? = nil
    ) async -> MailStore {
        let store = MailStore(
            source: fonte ?? InMemoryMailSource(
                accounts: [Self.conta], messages: [Self.mensagem()], agenda: []
            ),
            agendaPort: porta,
            agendaReferenceDay: { hoje }
        )
        await store.load()
        return store
    }

    /// O caminho inteiro do relato, em duas aberturas.
    ///
    /// Cai por mutação: tirando o `persist` de `addToAgenda`, a segunda
    /// abertura volta com a agenda vazia — o app que o dono usou.
    @Test("O compromisso colocado na agenda está lá na abertura seguinte")
    func sobreviveAoReinicio() async throws {
        let porta = AgendaEmMemoria()

        let primeira = await abertura(porta: porta)
        let mensagem = try #require(primeira.messages.first)
        let evento = try #require(mensagem.detectedEvent)
        let criado = try #require(primeira.addToAgenda(evento, from: mensagem))
        #expect(primeira.agenda.map(\.id) == [criado.id])

        let segunda = await abertura(porta: porta)
        #expect(segunda.agenda.map(\.id) == [criado.id])
        #expect(segunda.agenda.first?.title == criado.title)
        #expect(segunda.agenda.first?.startMinute == criado.startMinute)
    }

    /// **Sem conta conectada.** A fonte são as fixtures, e elas trazem a agenda
    /// de exemplo inteira a cada abertura. O compromisso que a pessoa criou
    /// entra junto: ele não é exemplo, e é dela.
    ///
    /// A agenda de exemplo continua intacta — a contagem das fixtures mais um.
    @Test("Sem conta, o compromisso criado entra junto com as fixtures")
    func sobreviveSemConta() async throws {
        let porta = AgendaEmMemoria()
        let fixtures = InMemoryMailSource.fixtures
        let quantasFixtures = Fixtures.month.count

        let primeira = await abertura(porta: porta, fonte: fixtures)
        let mensagem = try #require(primeira.messages.first { $0.detectedEvent != nil })
        let evento = try #require(mensagem.detectedEvent)
        let criado = try #require(primeira.addToAgenda(evento, from: mensagem))

        let segunda = await abertura(porta: porta, fonte: fixtures)
        #expect(segunda.agenda.count == quantasFixtures + 1)
        #expect(segunda.agenda.contains { $0.id == criado.id })
    }

    /// **A guarda contra a agenda em dobro atravessa o reinício.**
    ///
    /// A checagem de `UID` da M3-10 pergunta à lista `agenda`; se o `UID` não
    /// fosse guardado, a segunda abertura teria o compromisso sem identidade e
    /// o cartão do convite voltaria a dizer "Colocar na agenda" — um clique, e
    /// dois blocos idênticos, que é o defeito que a M3-10 consertou.
    ///
    /// Cai por mutação: não gravando o `calendarUID`, o estado na segunda
    /// abertura volta a `.ausente`.
    @Test("O UID do convite sobrevive, e o cartão continua dizendo Na agenda")
    func oUIDSobrevive() async throws {
        let porta = AgendaEmMemoria()
        var calendario = Calendar(identifier: .gregorian)
        calendario.timeZone = DreamSquad.saoPaulo

        let convite = DreamSquad.convite(sequence: 1)
        let mensagem = Message(
            id: "m-convite", accountID: "zoho",
            from: Contact(name: "Favini", address: "favini@vantion.com.br"),
            receivedAt: Self.hoje, subject: "Convite: DreamSquad", snippet: "",
            body: [], tags: [], bucket: .today, isRead: true,
            summary: nil, detectedEvent: nil,
            calendarICS: DreamSquad.ics(sequence: 1)
        )
        let fonte = InMemoryMailSource(
            accounts: [Self.conta], messages: [mensagem], agenda: []
        )

        let primeira = await abertura(porta: porta, fonte: fonte)
        #expect(primeira.addToAgenda(convite, from: mensagem) != nil)
        #expect(primeira.agenda.first?.calendarUID == DreamSquad.uid)

        // O encaminhamento do mesmo convite, na abertura seguinte: nada a fazer.
        let segunda = await abertura(porta: porta, fonte: fonte)
        #expect(segunda.agenda.first?.calendarUID == DreamSquad.uid)
        #expect(segunda.agendaState(for: convite, from: mensagem) == .naAgenda)
        #expect(segunda.addToAgenda(convite, from: mensagem) == nil)
        #expect(segunda.agenda.count == 1)
    }

    /// **O compromisso não anda de dia.**
    ///
    /// O `dayOffset` é relativo, e o "hoje" das telas de agenda com conta
    /// conectada é o relógio da máquina. Gravado cru, um compromisso de amanhã
    /// seria "amanhã" outra vez no dia seguinte, e no outro, para sempre — o
    /// compromisso fugindo um dia por abertura.
    ///
    /// Aqui o relógio é injetado: a primeira abertura é hoje, a segunda é
    /// amanhã. O compromisso criado para amanhã tem de aparecer como **hoje**
    /// na segunda.
    ///
    /// Cai por mutação: guardando `dayOffset` em vez do dia de calendário, a
    /// segunda abertura continua dizendo `+1`.
    @Test("O compromisso de amanhã é o de hoje no dia seguinte")
    func oDiaNaoAnda() async throws {
        let porta = AgendaEmMemoria()

        let primeira = await abertura(porta: porta)
        let mensagem = try #require(primeira.messages.first)
        let evento = try #require(mensagem.detectedEvent)
        let criado = try #require(primeira.addToAgenda(evento, from: mensagem))
        // A mensagem de exemplo cai dois dias à frente de `Fixtures.today`.
        #expect(criado.dayOffset == 2)

        let segunda = await abertura(porta: porta, hoje: Self.amanha)
        #expect(segunda.agenda.first?.dayOffset == 1)
    }

    /// "Desfazer" e "Tirar da agenda" também têm de alcançar o disco: senão
    /// reabrir traz de volta o que a pessoa acabou de tirar.
    @Test("Tirar da agenda tira para valer, e desfazer devolve para valer")
    func tirarEDevolver() async throws {
        let porta = AgendaEmMemoria()

        let primeira = await abertura(porta: porta)
        let mensagem = try #require(primeira.messages.first)
        let evento = try #require(mensagem.detectedEvent)
        let criado = try #require(primeira.addToAgenda(evento, from: mensagem))
        primeira.removeFromAgenda(criado.id)

        let segunda = await abertura(porta: porta)
        #expect(segunda.agenda.isEmpty)

        // E o "Desfazer" da faixa, ainda na primeira janela, devolve — inclusive
        // ao disco.
        primeira.restoreToAgenda(criado.id)
        let terceira = await abertura(porta: porta)
        #expect(terceira.agenda.map(\.id) == [criado.id])
    }
}

@Suite("A data do compromisso é a dele, não a da âncora")
struct AgendaDateTests {
    @Test("agendaDate soma o deslocamento do item ao hoje injetado")
    @MainActor func dataDoItemNaoEhAAncora() {
        let hoje = Date(timeIntervalSince1970: 1_787_000_000)
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: []),
            agendaReferenceDay: { hoje }
        )
        let item = AgendaItem(
            id: "ev-1", title: "Reunião",
            startMinute: 600, endMinute: 660, accountID: "conta-a", dayOffset: 3
        )
        let esperado = Calendar.current.date(byAdding: .day, value: 3, to: hoje)!
        // A janela de compromisso desenhava a âncora das fixtures para
        // qualquer evento; a data tem que ser a DO ITEM.
        #expect(store.agendaDate(for: item) == esperado)
        #expect(store.agendaDate(for: item) != hoje)
    }
}

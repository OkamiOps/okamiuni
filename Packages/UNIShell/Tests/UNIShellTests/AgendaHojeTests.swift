import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
import Synchronization
@testable import UNIShell

/// O "hoje" que a agenda desenha vem do relógio escolhido — e não da fixture.
///
/// O defeito: com conta conectada, a aba Agenda continuava destacando **terça,
/// 25 de agosto**, que é a âncora congelada do Marco 1, e a trilha do dia
/// continuava com o cabeçalho "Terça-feira, 25 de agosto". O `AgendaClock` já
/// sabia responder `today` (M3-4/M3-11) e o `MailStore` já o recebia; quem não
/// perguntava era a própria `InboxScreen`, que passava `Fixtures.today` cru
/// para a trilha e para a `CalendarScreen`.
@Suite("O hoje da agenda")
@MainActor
struct AgendaHojeTests {

    @Test("a semana mantém aniversário no dia 9 após a meia-noite")
    func aniversarioNaoMudaDeColuna() async throws {
        let calendar = Calendar.current
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 23))!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 3))!
        let time = Mutex(sunday)
        let birthday = AgendaItem(
            id: "birthday", title: "Meu aniversário · 9 setembro", startMinute: 0, endMinute: 1440,
            accountID: "calendar", dayOffset: 3, calendarID: "personal",
            calendarTitle: "Pessoal", calendarColorHex: "#8BA8BD"
        )
        let store = MailStore(
            source: InMemoryMailSource(accounts: [], messages: [], agenda: [birthday]),
            agendaReferenceDay: { time.withLock { $0 } }
        )
        await store.load()
        time.withLock { $0 = monday }
        store.updateAgendaDay()
        let screen = InboxScreen(store: store, clock: .fixed(195))
        let days = WeekAgenda.days(from: store.calendarAgenda, anchor: screen.agendaAnchor)
        #expect(days.first(where: { !$0.events.isEmpty })?.dayNumber == 9)
        #expect(days.first?.dayNumber == 7)
        let actual = try #require(Render.snapshot(
            screen.calendarContent, named: "agenda-aniversario-9-set-apos-meia-noite",
            size: CGSize(width: 1200, height: 900), theme: .tinta
        ))
        let expected = try #require(Render.bitmap(
            CalendarScreen(
                store: store, now: 195, anchor: monday,
                wantsSidebar: false, onCompose: {}, onOpenAccounts: {},
                showsSidebar: false
            ),
            size: CGSize(width: 1200, height: 900), theme: .tinta
        ))
        #expect(actual.pixelsDiffering(from: expected) == 0)
    }

    /// Sem conta, o mundo congelado; com conta, o dia da máquina. É a mesma
    /// regra do minuto, um degrau acima — e agora há **um** lugar onde ela é
    /// decidida para as três visões, a trilha e a lista.
    @Test("o hoje da agenda é o do relógio, e não o da fixture")
    func ancoraSegueORelogio() {
        let store = MailStore(source: InMemoryMailSource.fixtures)

        let congelado = InboxScreen(store: store, clock: .fixed(Fixtures.nowMinute))
        #expect(Calendar.current.isDate(congelado.agendaAnchor, inSameDayAs: Fixtures.today))

        let liveStore = MailStore(source: InMemoryMailSource.fixtures, agendaReferenceDay: { Date() })
        let vivo = InboxScreen(store: liveStore, clock: .live)
        #expect(
            Calendar.current.isDate(vivo.agendaAnchor, inSameDayAs: Date()),
            "com conta conectada o hoje da agenda tem de ser o dia da máquina"
        )
    }

    /// A prova por desenho, e não por propriedade: a faixa de dias da semana
    /// pinta o número de **hoje** no acento. Com o relógio vivo, a coluna
    /// tingida não pode ser a de 25 de agosto.
    ///
    /// A altura recortada é de propósito: cabeçalho (46) mais a faixa dos sete
    /// dias, e nada da grade. Assim a linha vermelha do "agora" fica fora do
    /// quadro e a comparação não depende do minuto em que a suíte roda.
    @Test("a aba Agenda com relógio vivo destaca o dia de hoje, não o da fixture")
    func abaAgendaDestacaHoje() async throws {
        try #require(
            !Calendar.current.isDate(Date(), inSameDayAs: Fixtures.today),
            "este caso só diz alguma coisa fora do dia da fixture"
        )
        let store = MailStore(source: InMemoryMailSource.fixtures, agendaReferenceDay: { Date() })
        await store.load()

        let tamanho = CGSize(width: 1200, height: CalendarHeader.height + 60)
        let agora = AgendaClock.minutesSinceMidnight()

        let vivo = try #require(
            Render.bitmap(
                InboxScreen(store: store, clock: .live).calendarContent,
                size: tamanho, theme: .tinta
            )
        )
        let comFixture = try #require(
            Render.bitmap(
                CalendarScreen(
                    store: store, now: agora, anchor: Fixtures.today,
                    wantsSidebar: false, onCompose: {}, onOpenAccounts: {},
                    showsSidebar: false
                ),
                size: tamanho, theme: .tinta
            )
        )
        #expect(
            vivo.pixelsDiffering(from: comFixture) > 0,
            "a aba Agenda está desenhando o 25 de agosto congelado"
        )

        let comHoje = try #require(
            Render.bitmap(
                CalendarScreen(
                    store: store, now: agora, anchor: Date(),
                    wantsSidebar: false, onCompose: {}, onOpenAccounts: {},
                    showsSidebar: false
                ),
                size: tamanho, theme: .tinta
            )
        )
        #expect(vivo.pixelsDiffering(from: comHoje) == 0)
    }

    /// A trilha do dia: o cabeçalho dela dizia "Terça, 25 de agosto" com
    /// qualquer conta no ar.
    ///
    /// O shell novo não monta mais a quarta coluna — o que o dono precisava
    /// dela virou a cápsula "Próximo: … em N min" no topo do leitor — então a
    /// garantia foi partida nos dois pedaços que ela sempre teve, e os dois
    /// continuam provados: `ancoraSegueORelogio` diz que a âncora da tela é a
    /// do relógio, e este caso diz que a trilha **desenha** a data que recebe,
    /// em vez de reescrever a da fixture por dentro.
    ///
    /// O relógio é o mesmo nos dois lados de propósito: a linha de baixo do
    /// cabeçalho ("Próximo · …") e o traço vermelho seguem o minuto, e com o
    /// mesmo minuto eles saem idênticos. Sobra a data.
    @Test("a trilha do dia desenha a data que recebe, e não a da fixture")
    func trilhaSegueORelogio() async throws {
        try #require(!Calendar.current.isDate(Date(), inSameDayAs: Fixtures.today))
        let store = MailStore(source: InMemoryMailSource.fixtures, agendaReferenceDay: { Date() })
        await store.load()

        let tamanho = CGSize(width: AgendaRail.width, height: 120)
        let agora = AgendaClock.minutesSinceMidnight()
        let vivo = InboxScreen(store: store, clock: .live)
        // A âncora da tela, que é a do relógio: é ela que o shell entrega.
        #expect(Calendar.current.isDate(vivo.agendaAnchor, inSameDayAs: Date()))

        let comHoje = try #require(
            Render.bitmap(
                AgendaRail(
                    store: store, now: agora, headerDate: vivo.agendaAnchor,
                    width: AgendaRail.width
                ),
                size: tamanho, theme: .tinta
            )
        )
        let comFixture = try #require(
            Render.bitmap(
                AgendaRail(
                    store: store, now: agora, headerDate: Fixtures.today,
                    width: AgendaRail.width
                ),
                size: tamanho, theme: .tinta
            )
        )
        #expect(
            comHoje.pixelsDiffering(from: comFixture) > 0,
            "o cabeçalho da trilha não está escrevendo a data que recebe"
        )
    }
}

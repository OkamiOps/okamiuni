import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
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

    /// Sem conta, o mundo congelado; com conta, o dia da máquina. É a mesma
    /// regra do minuto, um degrau acima — e agora há **um** lugar onde ela é
    /// decidida para as três visões, a trilha e a lista.
    @Test("o hoje da agenda é o do relógio, e não o da fixture")
    func ancoraSegueORelogio() {
        let store = MailStore(source: InMemoryMailSource.fixtures)

        let congelado = InboxScreen(store: store, clock: .fixed(Fixtures.nowMinute))
        #expect(Calendar.current.isDate(congelado.agendaAnchor, inSameDayAs: Fixtures.today))

        let vivo = InboxScreen(store: store, clock: .live)
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
        let store = MailStore(source: InMemoryMailSource.fixtures)
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
                CalendarScreen(store: store, now: agora, anchor: Fixtures.today),
                size: tamanho, theme: .tinta
            )
        )
        #expect(
            vivo.pixelsDiffering(from: comFixture) > 0,
            "a aba Agenda está desenhando o 25 de agosto congelado"
        )

        let comHoje = try #require(
            Render.bitmap(
                CalendarScreen(store: store, now: agora, anchor: Date()),
                size: tamanho, theme: .tinta
            )
        )
        #expect(vivo.pixelsDiffering(from: comHoje) == 0)
    }

    /// A trilha do dia, ao lado do leitor: o cabeçalho dela dizia "Terça,
    /// 25 de agosto" com qualquer conta no ar.
    ///
    /// Duas escolhas mantêm a data como **única** diferença possível entre os
    /// dois desenhos. As colunas comparadas são só as da trilha, porque a
    /// lista à esquerda já segue o relógio desde a M3-11. E o relógio congelado
    /// leva o minuto **de agora**, e não o meio-dia da fixture: a linha de baixo
    /// do cabeçalho ("Próximo · …") e o traço vermelho seguem o minuto, que já
    /// era vivo desde a M3-4, e com o mesmo minuto dos dois lados eles saem
    /// idênticos. Sobra a data.
    @Test("a trilha do dia com relógio vivo tem a data de hoje no cabeçalho")
    func trilhaSegueORelogio() async throws {
        try #require(!Calendar.current.isDate(Date(), inSameDayAs: Fixtures.today))
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        let largura: CGFloat = 1440
        let tamanho = CGSize(width: largura, height: 120)
        let trilha = Int(largura - AgendaRail.width)..<Int(largura)

        let vivo = try #require(
            Render.bitmap(
                InboxScreen(store: store, clock: .live).mailContent,
                size: tamanho, theme: .tinta
            )
        )
        let congelado = try #require(
            Render.bitmap(
                InboxScreen(
                    store: store, clock: .fixed(AgendaClock.minutesSinceMidnight())
                ).mailContent,
                size: tamanho, theme: .tinta
            )
        )
        #expect(
            vivo.pixelsDiffering(from: congelado, inColumns: trilha) > 0,
            "o cabeçalho da trilha continua com a data da fixture"
        )
    }
}

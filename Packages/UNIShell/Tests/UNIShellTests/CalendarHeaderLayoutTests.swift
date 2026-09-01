import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
@testable import UNIShell

/// Os controles da faixa da agenda não podem andar quando a data muda.
///
/// O defeito, do print do dono: em "Julho 2026" as abas Dia/Semana/Mês, o
/// `‹ ›`, o "Hoje" e a contagem estavam num lugar; em "Agosto 2026" estavam
/// noutro, porque o título é o primeiro item de um `HStack` e um mês mais
/// largo empurra tudo o que vem depois. Quem navega com cliques repetidos em
/// `›` vê o botão fugir do cursor.
///
/// A régua é o desenho: as abas Dia/Semana/Mês têm fundo `surface3`, e nada
/// mais na faixa tem. A primeira e a última coluna em que essa cor aparece
/// **são** a posição das abas — e a primeira delas fica logo depois do título,
/// então ela também prova que as abas não andaram. As duas têm de ser as
/// mesmas nos dois desenhos. O navegador (`‹` data `›` Hoje) é chip `btn`
/// e não entra nesta régua.
///
/// A largura é 1440, a da janela padrão. Não é detalhe: com quatro contas e a
/// faixa apertada (1100 já basta), o `HStack` passa a comprimir o que não cabe,
/// e aí as posições mudam por falta de espaço — outro assunto, e não este.
@Suite("Faixa da agenda: os controles não andam")
@MainActor
struct CalendarHeaderLayoutTests {

    private static let tamanho = CGSize(width: 1440, height: CalendarHeader.height)

    private func faixa(
        mode: CalendarViewMode, offset: Int, store: MailStore
    ) -> NSBitmapImageRep? {
        Render.bitmap(
            CalendarHeader(
                store: store,
                anchor: Fixtures.today,
                mode: mode,
                selectedDayOffset: offset,
                pickerOpen: false,
                onPick: { _ in }, onStepDay: { _ in }, onGoToday: {},
                onTogglePicker: {}, onPickDay: { _ in }
            ),
            size: Self.tamanho,
            theme: .tinta
        )
    }

    /// Visão Semana, de agosto para julho — os dois meses do print.
    @Test("mudar de mês não move as abas nem os botões")
    func mesNaoMoveOsControles() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        let agosto = try #require(faixa(mode: .week, offset: 0, store: store))
        let julho = try #require(faixa(mode: .week, offset: -30, store: store))

        // Sanidade: os dois desenhos **são** diferentes (o título mudou). Sem
        // isto, um caso que comparasse a mesma imagem consigo mesma passaria.
        #expect(agosto.pixelsDiffering(from: julho) > 0)

        #expect(
            agosto.columns(matching: Theme.tinta.surface3)
                == julho.columns(matching: Theme.tinta.surface3),
            "as abas e os botões ‹ › Hoje mudaram de lugar entre julho e agosto"
        )
    }

    /// Visão Dia, título curto contra título longo — e, junto com ele, o
    /// rótulo "ter, 25 ago" do botão do seletor, que também mudava de largura
    /// e levava o `›` e o "Hoje" embora.
    @Test("data curta e data longa deixam os botões no mesmo lugar")
    func diaCurtoEDiaLongoNaoMovemOsControles() async throws {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()

        // 25/08/2026 é terça: "Terça, 25 de agosto" e "ter, 25 ago".
        let curto = try #require(faixa(mode: .day, offset: 0, store: store))
        // 2/09/2026 é quarta: "Quarta, 2 de setembro" e "qua, 2 set".
        let longo = try #require(faixa(mode: .day, offset: 8, store: store))

        #expect(curto.pixelsDiffering(from: longo) > 0)

        #expect(
            curto.columns(matching: Theme.tinta.surface3)
                == longo.columns(matching: Theme.tinta.surface3),
            "os botões do navegador mudaram de lugar entre um dia e outro"
        )
    }
}

import Foundation
import Testing
@testable import UNICore

/// Os pedaços que a faixa da agenda mede para reservar a largura do título.
///
/// O defeito que eles consertam: em "Julho 2026" os botões Dia/Semana/Mês,
/// `‹ ›` e "Hoje" ficavam num lugar e em "Agosto 2026" noutro, porque o título
/// mais largo empurrava a barra inteira. Aqui se prova a parte que é dado — que
/// os pedaços **cobrem** todos os títulos do ano. Que os botões param de andar
/// é `CalendarHeaderLayoutTests`, no UNIShell, que compara dois desenhos.
@Suite("Reserva de largura do título da agenda")
struct CalendarTitleReserveTests {

    private let calendario = Calendar(identifier: .gregorian)
    private var anoDe: Date {
        Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: 2026, month: 8, day: 25))!
    }

    @Test("os doze títulos de mês do ano saem completos")
    func dozeMeses() {
        let titulos = CalendarTitleReserve.monthTitles(inYearOf: anoDe, calendar: calendario)
        #expect(titulos.count == 12)
        #expect(titulos.first == "Janeiro 2026")
        #expect(titulos.contains("Agosto 2026"))
        #expect(titulos.last == "Dezembro 2026")
    }

    /// A prova de cobertura: qualquer dia do ano, com o número trocado pelo
    /// pior caso de dois algarismos, é um dos prefixos seguido de um dos
    /// sufixos. Se a decomposição perder um dia da semana ou um mês, algum dia
    /// do ano deixa de ser coberto e a reserva sai curta.
    @Test("os pedaços da visão Dia cobrem os 365 títulos do ano")
    func pedacosCobremOAno() throws {
        let (prefixos, sufixos) = CalendarTitleReserve.longDayTitlePieces(
            inYearOf: anoDe, calendar: calendario
        )
        #expect(prefixos.count == 7)
        #expect(sufixos.count == 12)

        let possiveis = Set(prefixos.flatMap { p in sufixos.map { p + $0 } })
        for offset in 0..<365 {
            let titulo = MonthAgenda.longDayTitle(
                dayOffset: offset, anchor: anoDe, calendar: calendario
            )
            #expect(
                possiveis.contains(comNumeroDePiorCaso(titulo)),
                "«\(titulo)» não é coberto por nenhum par de pedaços"
            )
        }
    }

    @Test("os pedaços do seletor cobrem os 365 rótulos do ano")
    func pedacosDoSeletorCobremOAno() throws {
        let (prefixos, sufixos) = CalendarTitleReserve.shortDayLabelPieces(
            inYearOf: anoDe, calendar: calendario
        )
        #expect(prefixos.count == 7)
        #expect(sufixos.count == 12)

        let possiveis = Set(prefixos.flatMap { p in sufixos.map { p + $0 } })
        for offset in 0..<365 {
            let rotulo = MonthAgenda.shortDayLabel(
                dayOffset: offset, anchor: anoDe, calendar: calendario
            )
            #expect(
                possiveis.contains(comNumeroDePiorCaso(rotulo)),
                "«\(rotulo)» não é coberto por nenhum par de pedaços"
            )
        }
    }

    /// Troca o número do dia por "30", que é o pior caso de largura da reserva.
    private func comNumeroDePiorCaso(_ texto: String) -> String {
        var saida = ""
        var trocado = false
        var index = texto.startIndex
        while index < texto.endIndex {
            if texto[index].isNumber {
                var fim = index
                while fim < texto.endIndex, texto[fim].isNumber { fim = texto.index(after: fim) }
                saida += trocado ? String(texto[index..<fim]) : "30"
                trocado = true
                index = fim
            } else {
                saida.append(texto[index])
                index = texto.index(after: index)
            }
        }
        return saida
    }
}

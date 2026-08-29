import Foundation
import Testing
@testable import UNICore

/// Uma porta de agenda em memória, com o mesmo contrato da de disco. É o que
/// deixa a regra de guardar e reler ser provada sem banco nenhum — o banco tem
/// os testes dele em `UNISync`.
final class AgendaEmMemoria: AgendaPersisting, @unchecked Sendable {
    private let trava = NSLock()
    private var guardados: [String: StoredAgendaItem] = [:]

    init(_ iniciais: [StoredAgendaItem] = []) {
        for item in iniciais { guardados[item.id] = item }
    }

    func saveAgendaItem(_ item: StoredAgendaItem) throws {
        trava.lock(); defer { trava.unlock() }
        guardados[item.id] = item
    }

    func removeAgendaItem(_ id: String) throws {
        trava.lock(); defer { trava.unlock() }
        guardados[id] = nil
    }

    func savedAgendaItems() throws -> [StoredAgendaItem] {
        trava.lock(); defer { trava.unlock() }
        return guardados.values.sorted { $0.id < $1.id }
    }
}

private let calendario = Calendar(identifier: .gregorian)

/// Terça, 25 de agosto de 2026, meio-dia — o "hoje" do protótipo.
private let hoje = Fixtures.today
/// O dia seguinte, para o relógio que anda.
private let amanha = calendario.date(byAdding: .day, value: 1, to: hoje)!

@Suite("O dia de um compromisso guardado")
struct CivilDayTests {

    @Test("O deslocamento vira dia de calendário, e volta igual")
    func idaEVolta() throws {
        for offset in [-7, -1, 0, 1, 30] {
            let dia = CivilDay.from(dayOffset: offset, reference: hoje, calendar: calendario)
            #expect(dia.dayOffset(from: hoje, calendar: calendario) == offset)
        }
    }

    @Test("O amanhã de hoje é o hoje de amanhã")
    func oAmanhaAnda() {
        let dia = CivilDay.from(dayOffset: 1, reference: hoje, calendar: calendario)
        #expect(dia == CivilDay(year: 2026, month: 8, day: 26))
        // O mesmo dia civil, lido no dia seguinte, é "hoje" — e não "amanhã"
        // outra vez. É esta conta que impede o compromisso de andar sozinho.
        #expect(dia.dayOffset(from: amanha, calendar: calendario) == 0)
    }

    @Test("O texto do banco é o dia, e volta a ser o dia")
    func oTexto() throws {
        let dia = CivilDay(year: 2026, month: 8, day: 30)
        #expect(dia.iso == "2026-08-30")
        #expect(CivilDay(iso: "2026-08-30") == dia)
        #expect(CivilDay(iso: "coisa nenhuma") == nil)
        #expect(CivilDay(iso: "2026-13-01") == nil)
    }

    /// O compromisso inteiro atravessa: horário, conta, `UID`, versão e o
    /// detalhe que a janela 04 mostra.
    @Test("O compromisso guardado volta inteiro")
    func oCompromissoInteiro() {
        let detalhe = EventDetail(
            place: "Sala 3", link: "https://meet.exemplo/abc",
            organizer: EventPerson(
                name: "Favini", address: "favini@x.com", role: "organizador", status: .yes
            ),
            people: [
                EventPerson(name: "Ana", address: "ana@x.com", role: "convidado", status: .pending)
            ],
            note: "Do convite por email · conta zoho",
            recurrence: "Evento único", notice: "Sem alerta", agenda: [],
            thread: [EventThreadEntry(when: "25 ago 09:00", who: "Favini", what: "Call", kind: .email)],
            descricao: "A pauta."
        )
        let item = AgendaItem(
            id: "email-m1", title: "Call de contrato",
            startMinute: 570, endMinute: 600, accountID: "zoho", dayOffset: 2,
            calendarUID: "uid-1", calendarSequence: 3, detail: detalhe
        )

        let guardado = StoredAgendaItem(item, referenceDay: hoje, calendar: calendario)
        #expect(guardado.day == CivilDay(year: 2026, month: 8, day: 27))
        #expect(guardado.item(referenceDay: hoje, calendar: calendario) == item)
    }
}

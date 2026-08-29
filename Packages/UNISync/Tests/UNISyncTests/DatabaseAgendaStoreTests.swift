import Foundation
import GRDB
import Testing
import UNICore
@testable import UNISync

/// A porta de agenda do disco: o outro lado do defeito "coloco o item no
/// calendário e ao fechar e abrir o OkamiUNI a agenda some".
///
/// As regras de merge e de fuso são provadas em `UNICore`
/// (`AgendaSurvivesRestartTests`, `CivilDayTests`). Aqui prova-se o disco: a
/// tabela existe, o compromisso vai e volta inteiro, e **sem conta cadastrada**
/// — que é onde a `agenda_item` da v1 não serviria, por causa da chave
/// estrangeira para `account`.
@Suite("A agenda no disco")
struct DatabaseAgendaStoreTests {

    private func banco() throws -> SyncDatabase { try SyncDatabase.temporary() }

    private var detalhe: EventDetail {
        EventDetail(
            place: "Google Meet", link: "https://meet.google.com/abc-defg-hij",
            organizer: EventPerson(
                name: "Favini", address: "favini@vantion.com.br",
                role: "organizador", status: .yes
            ),
            people: [
                EventPerson(name: "Ana", address: "ana@x.com", role: "convidado", status: .pending),
                EventPerson(name: "Bruno", address: "bruno@x.com", role: "convidado", status: .maybe),
            ],
            note: "Do convite por email · conta vantion",
            recurrence: "Evento único", notice: "Sem alerta",
            agenda: ["Contrato", "Prazos"],
            thread: [
                EventThreadEntry(
                    when: "25 ago 09:00", who: "Favini", what: "Convite: DreamSquad", kind: .email
                )
            ],
            descricao: "A pauta que o organizador escreveu."
        )
    }

    private var compromisso: StoredAgendaItem {
        StoredAgendaItem(
            id: "email-m1", title: "DreamSquad",
            startMinute: 594, endMinute: 644,
            accountID: "conta-que-nao-existe-na-tabela-account",
            day: CivilDay(year: 2026, month: 9, day: 1),
            calendarUID: "3n4k5m6l7@google.com", calendarSequence: 2,
            detail: detalhe
        )
    }

    @Test("A migração v5 cria a tabela dos compromissos criados, e o índice do UID")
    func migracaoV5() throws {
        let db = try banco()
        let tabelas = try db.pool.read { conexao -> Set<String> in
            try String.fetchSet(conexao, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tabelas.contains("created_agenda_item"))

        let indices = try db.pool.read { conexao -> Set<String> in
            try String.fetchSet(conexao, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        #expect(indices.contains("created_agenda_on_uid"))
    }

    /// **Sem uma linha em `account`.** É o caso de quem ainda não conectou
    /// conta nenhuma e criou um compromisso a partir de uma mensagem de
    /// exemplo. Com a chave estrangeira da `agenda_item` da v1, este `INSERT`
    /// seria recusado e a agenda continuaria sumindo.
    @Test("O compromisso é gravado sem conta cadastrada, e volta inteiro")
    func vaiEVoltaSemConta() throws {
        let db = try banco()
        #expect(try db.pool.read { try AccountRecord.fetchCount($0) } == 0)

        let porta = DatabaseAgendaStore(database: db)
        try porta.saveAgendaItem(compromisso)

        let devolvidos = try porta.savedAgendaItems()
        #expect(devolvidos == [compromisso])
    }

    /// Gravar duas vezes o mesmo `id` é "Atualizar na agenda", não um segundo
    /// compromisso — é a mesma guarda contra a agenda em dobro, um nível abaixo.
    @Test("Gravar de novo o mesmo id atualiza, e não duplica")
    func atualizaEmVezDeDuplicar() throws {
        let db = try banco()
        let porta = DatabaseAgendaStore(database: db)
        try porta.saveAgendaItem(compromisso)

        let mudado = StoredAgendaItem(
            id: compromisso.id, title: "DreamSquad (novo horário)",
            startMinute: 700, endMinute: 750,
            accountID: compromisso.accountID,
            day: CivilDay(year: 2026, month: 9, day: 2),
            calendarUID: compromisso.calendarUID, calendarSequence: 3,
            detail: compromisso.detail
        )
        try porta.saveAgendaItem(mudado)

        #expect(try porta.savedAgendaItems() == [mudado])
    }

    @Test("Tirar tira, e tirar o que não está lá não é erro")
    func tirar() throws {
        let db = try banco()
        let porta = DatabaseAgendaStore(database: db)
        try porta.saveAgendaItem(compromisso)
        try porta.removeAgendaItem(compromisso.id)
        #expect(try porta.savedAgendaItems().isEmpty)
        try porta.removeAgendaItem(compromisso.id)
        #expect(try porta.savedAgendaItems().isEmpty)
    }

    /// O compromisso sem detalhe — o detectado no texto de um email — volta
    /// **sem detalhe**, e não com um vazio: `nil` ali é o que faz a janela 04
    /// cair em `Fixtures.eventDetail(for:)` como sempre caiu.
    @Test("Sem detalhe vai e volta sem detalhe")
    func semDetalhe() throws {
        let db = try banco()
        let porta = DatabaseAgendaStore(database: db)
        let simples = StoredAgendaItem(
            id: "email-m2", title: "Call de contrato",
            startMinute: 900, endMinute: 930, accountID: "zoho",
            day: CivilDay(year: 2026, month: 8, day: 27)
        )
        try porta.saveAgendaItem(simples)
        let devolvido = try #require(try porta.savedAgendaItems().first)
        #expect(devolvido == simples)
        #expect(devolvido.detail == nil)
    }

    /// A tabela guarda **dia de calendário**, não deslocamento. É a garantia,
    /// no disco, de que o compromisso de amanhã não anda um dia por abertura.
    @Test("A coluna do dia guarda a data civil")
    func aColunaDoDia() throws {
        let db = try banco()
        try DatabaseAgendaStore(database: db).saveAgendaItem(compromisso)
        let gravado = try db.pool.read { conexao -> String? in
            try String.fetchOne(
                conexao, sql: "SELECT day FROM created_agenda_item WHERE id = ?",
                arguments: [compromisso.id]
            )
        }
        #expect(gravado == "2026-09-01")
    }
}

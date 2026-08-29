import Foundation
import GRDB
import UNICore

/// A porta de agenda **do disco**: onde os compromissos que a pessoa criou
/// passam a noite.
///
/// Ver `UNICore.AgendaPersisting` para o defeito que ela conserta ("coloco o
/// item no calendário e ao fechar e abrir o OkamiUNI a agenda some") e para o
/// que ela deliberadamente **não** guarda: a agenda de exemplo continua vindo
/// das fixtures, e a agenda de um servidor é o Marco 4.
///
/// Síncrona, como o protocolo pede: quem lê é a montagem do retrato. São
/// leituras e escritas numa tabela de dezenas de linhas em SQLite local — o
/// mesmo disco que a lista de mensagens já lê para desenhar.
public struct DatabaseAgendaStore: AgendaPersisting {
    private let database: SyncDatabase

    public init(database: SyncDatabase) {
        self.database = database
    }

    public func saveAgendaItem(_ item: StoredAgendaItem) throws {
        try database.pool.write { db in
            // `save` é upsert pela chave primária: "Colocar na agenda" e
            // "Atualizar na agenda" são a mesma escrita, porque o `id` de um
            // compromisso é estável por construção
            // (`DetectedEventConversion.agendaID(forMessageID:)`) e a
            // atualização de um convite o preserva de propósito.
            try CreatedAgendaItemRecord(item).save(db)
        }
    }

    public func removeAgendaItem(_ id: String) throws {
        _ = try database.pool.write { db in
            try CreatedAgendaItemRecord.deleteOne(db, key: id)
        }
    }

    public func savedAgendaItems() throws -> [StoredAgendaItem] {
        try database.pool.read { db in
            try CreatedAgendaItemRecord.fetchAll(db).map(\.stored)
        }
    }
}

// MARK: - A linha

/// A linha de `created_agenda_item`.
///
/// Ela é a **fronteira do formato**, e por isso mora aqui e não em `UNICore`:
/// os tipos do modelo (`EventDetail`, `EventPerson`, `EventThreadEntry`) não
/// conhecem JSON nem coluna nenhuma, e não têm por que conhecer. Quem quiser
/// mudar o desenho da janela 04 mexe lá; quem mudar o formato do disco mexe
/// aqui, e a migração fica ao lado.
struct CreatedAgendaItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "created_agenda_item"

    var id: String
    var accountID: String
    var title: String
    /// O dia civil, "AAAA-MM-DD". Ver `CivilDay` — e a nota da migração v5
    /// sobre por que **não** é um deslocamento.
    var day: String
    var startMinute: Int
    var endMinute: Int
    var calendarUID: String?
    var calendarSequence: Int?
    var place: String?
    var link: String?
    var descricao: String?
    var note: String?
    var recurrence: String?
    var notice: String?
    var organizerJSON: String?
    var peopleJSON: String?
    var agendaJSON: String?
    var threadJSON: String?

    init(_ item: StoredAgendaItem) {
        id = item.id
        accountID = item.accountID
        title = item.title
        day = item.day.iso
        startMinute = item.startMinute
        endMinute = item.endMinute
        calendarUID = item.calendarUID
        calendarSequence = item.calendarSequence
        // `place` é o que distingue "tem detalhe" de "não tem": ele é o único
        // campo não-opcional de `EventDetail`, e é por ele que a leitura decide
        // se remonta o detalhe ou devolve `nil`.
        place = item.detail?.place
        link = item.detail?.link
        descricao = item.detail?.descricao
        note = item.detail?.note
        recurrence = item.detail?.recurrence
        notice = item.detail?.notice
        organizerJSON = item.detail.map { AgendaJSON.pessoa($0.organizer) }
        peopleJSON = item.detail.map { AgendaJSON.pessoas($0.people) }
        agendaJSON = item.detail.map { AgendaJSON.textos($0.agenda) }
        threadJSON = item.detail.map { AgendaJSON.trilha($0.thread) }
    }

    var stored: StoredAgendaItem {
        StoredAgendaItem(
            id: id, title: title,
            startMinute: startMinute, endMinute: endMinute,
            accountID: accountID,
            // Dia ilegível vira "hoje" em vez de derrubar a leitura inteira: um
            // compromisso no dia errado é ruim, e a agenda inteira sumindo por
            // causa de uma linha estragada é pior — a mesma escolha que
            // `DatabaseMailSource.messages` faz com o corpo duplicado.
            day: CivilDay(iso: day) ?? CivilDay.from(dayOffset: 0, reference: Date()),
            calendarUID: calendarUID,
            calendarSequence: calendarSequence,
            detail: detalhe
        )
    }

    private var detalhe: EventDetail? {
        guard let place, let organizerJSON,
              let organizador = AgendaJSON.pessoa(de: organizerJSON)
        else { return nil }
        return EventDetail(
            place: place, link: link,
            organizer: organizador,
            people: peopleJSON.map(AgendaJSON.pessoas(de:)) ?? [],
            note: note ?? "",
            recurrence: recurrence ?? "",
            notice: notice ?? "",
            agenda: agendaJSON.map(AgendaJSON.textos(de:)) ?? [],
            thread: threadJSON.map(AgendaJSON.trilha(de:)) ?? [],
            descricao: descricao
        )
    }
}

// MARK: - O JSON das listas

/// As formas de disco dos tipos compostos do `EventDetail`.
///
/// Espelhos declarados, e não `Codable` pendurado nos tipos de `UNICore`: assim
/// o formato do banco é uma decisão deste arquivo, e renomear um campo do
/// modelo não muda calado o que já está gravado no disco de alguém.
enum AgendaJSON {

    private struct Pessoa: Codable {
        var name: String
        var address: String
        var role: String
        var status: String

        init(_ p: EventPerson) {
            name = p.name; address = p.address; role = p.role; status = p.status.rawValue
        }

        var pessoa: EventPerson {
            EventPerson(
                name: name, address: address, role: role,
                status: EventPerson.Status(rawValue: status) ?? .pending
            )
        }
    }

    private struct Linha: Codable {
        var when: String
        var who: String
        var what: String
        var kind: String

        init(_ e: EventThreadEntry) {
            when = e.when; who = e.who; what = e.what; kind = e.kind.rawValue
        }

        var entrada: EventThreadEntry {
            EventThreadEntry(
                when: when, who: who, what: what,
                kind: EventThreadEntry.Kind(rawValue: kind) ?? .system
            )
        }
    }

    /// JSON ilegível é lista vazia, nunca um `throw`: uma linha estragada não
    /// pode custar a agenda inteira. Ver a nota de `stored`.
    private static func texto<T: Encodable>(_ valor: T) -> String {
        (try? JSONEncoder().encode(valor)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func valor<T: Decodable>(_ json: String, _ tipo: T.Type) -> T? {
        guard let dados = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(tipo, from: dados)
    }

    static func pessoa(_ quem: EventPerson) -> String { texto(Pessoa(quem)) }
    static func pessoa(de json: String) -> EventPerson? { valor(json, Pessoa.self)?.pessoa }

    static func pessoas(_ gente: [EventPerson]) -> String { texto(gente.map(Pessoa.init)) }
    static func pessoas(de json: String) -> [EventPerson] {
        valor(json, [Pessoa].self)?.map(\.pessoa) ?? []
    }

    static func textos(_ linhas: [String]) -> String { texto(linhas) }
    static func textos(de json: String) -> [String] { valor(json, [String].self) ?? [] }

    static func trilha(_ linhas: [EventThreadEntry]) -> String { texto(linhas.map(Linha.init)) }
    static func trilha(de json: String) -> [EventThreadEntry] {
        valor(json, [Linha].self)?.map(\.entrada) ?? []
    }
}

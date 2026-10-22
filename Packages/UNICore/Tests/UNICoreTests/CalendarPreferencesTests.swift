import Foundation
import Testing
@testable import UNICore

/// Os padrões da aba Agendas. O que se prova aqui é que eles **chegam** — no
/// editor de compromisso novo e no item que nasce dele — e não só que ficaram
/// guardados: uma preferência que só persiste é um controle mudo.
@Suite("Os padrões da Agenda", .serialized)
@MainActor
struct CalendarPreferencesTests {

    private func preferences() throws -> (CalendarPreferences, UserDefaults, String) {
        let suite = "okamiuni.calendar-prefs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (CalendarPreferences(defaults: defaults), defaults, suite)
    }

    @Test("Sem nada guardado, abre em 30 min e aviso de 10 min")
    func padroesDeFabrica() throws {
        let (prefs, _, suite) = try preferences()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(prefs.durationMinutes == 30)
        #expect(prefs.alert == .minutes(10))
        #expect(prefs.weekStart == .monday)
        #expect(prefs.workingHours == WorkingHours(startMinute: 9 * 60, endMinute: 18 * 60))
        #expect(prefs.defaultCalendarID == nil)
    }

    @Test("A duração, a agenda e o aviso chegam ao editor de compromisso novo")
    func padroesChegamAoEditor() throws {
        let (prefs, _, suite) = try preferences()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        prefs.durationMinutes = 90
        prefs.alert = .minutes(15)
        prefs.defaultCalendarID = "okamiuni.email"
        prefs.defaultRoom = .meet

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let abertura = prefs.newAppointment(startingAt: start)

        #expect(abertura.start == start)
        #expect(abertura.durationMinutes == 90)
        #expect(abertura.end == start.addingTimeInterval(90 * 60))
        #expect(abertura.calendarID == "okamiuni.email")
        #expect(abertura.alert == .minutes(15))
        #expect(abertura.room == .meet)
    }

    @Test("A escolha sobrevive a fechar e reabrir a janela")
    func persiste() throws {
        let suite = "okamiuni.calendar-prefs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        let primeira = CalendarPreferences(defaults: defaults)
        primeira.durationMinutes = 45
        primeira.alert = .none
        primeira.weekStart = .sunday
        primeira.workingHours = nil
        primeira.defaultRoom = .zoom

        let segunda = CalendarPreferences(defaults: defaults)
        #expect(segunda.durationMinutes == 45)
        #expect(segunda.alert == .none)
        #expect(segunda.weekStart == .sunday)
        #expect(segunda.workingHours == nil)
        #expect(segunda.defaultRoom == .zoom)
    }

    @Test("O aviso vai e volta pelo texto que o compromisso guarda")
    func avisoDaIdaEVolta() {
        for alerta in CalendarAlert.allCases {
            #expect(
                CalendarAlert.fromNotice(alerta.notice) == alerta,
                "o aviso \(alerta) não voltou do texto \(alerta.notice)"
            )
        }
    }

    /// A frase que o EventKit devolve num evento importado **não** pode virar
    /// aviso: um palpite em cima dela apagaria ou inventaria alarme num
    /// compromisso que não é nosso toda vez que ele fosse regravado.
    @Test("Texto de fora não vira aviso")
    func avisoDeForaNaoConta() {
        #expect(CalendarAlert.fromNotice("Consulte o Calendário para alertas") == nil)
        #expect(CalendarAlert.fromNotice("Sem lembrete") == nil)
        #expect(CalendarAlert.fromNotice("") == nil)
        #expect(CalendarAlert.fromNotice(nil) == nil)
    }

    @Test("A sala por conta sobe uma vez para a preferência global")
    func migracaoDaSala() throws {
        let suite = "okamiuni.calendar-prefs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        let rooms = MeetingRoomSettingsStore(defaults: defaults)
        rooms.setDefault(.zoho, for: "conta-b")

        let prefs = CalendarPreferences(defaults: defaults)
        prefs.migrateRoom(from: rooms, accountIDs: ["conta-a", "conta-b"])
        #expect(prefs.defaultRoom == .zoho)

        // A segunda vez não mexe mais: quem trocou a global depois da
        // migração não pode ser atropelado pelo perfil velho.
        prefs.defaultRoom = nil
        prefs.migrateRoom(from: rooms, accountIDs: ["conta-a", "conta-b"])
        #expect(prefs.defaultRoom == nil)
    }

    @Test("A semana começa onde a preferência diz, e a grade anda junto")
    func inicioDaSemana() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Terça, 25/08/2026.
        let terca = calendar.date(from: DateComponents(year: 2_026, month: 8, day: 25))!

        let segunda = WeekAgenda.weekOffsets(
            for: terca, calendar: calendar,
            firstWeekday: CalendarWeekStart.monday.rawValue
        )
        #expect(segunda == [-1, 0, 1, 2, 3, 4, 5])

        let domingo = WeekAgenda.weekOffsets(
            for: terca, calendar: calendar,
            firstWeekday: CalendarWeekStart.sunday.rawValue
        )
        #expect(domingo == [-2, -1, 0, 1, 2, 3, 4])

        let sabado = WeekAgenda.weekOffsets(
            for: terca, calendar: calendar,
            firstWeekday: CalendarWeekStart.saturday.rawValue
        )
        #expect(sabado == [-3, -2, -1, 0, 1, 2, 3])
    }

    /// O padrão de quem não passa nada continua sendo segunda — ler
    /// `Calendar.current.firstWeekday` moveria a grade de todo mundo em pt-BR.
    @Test("Sem preferência, a grade continua em segunda")
    func padraoContinuaSegunda() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 1
        let terca = calendar.date(from: DateComponents(year: 2_026, month: 8, day: 25))!
        #expect(WeekAgenda.weekOffsets(for: terca, calendar: calendar) == [-1, 0, 1, 2, 3, 4, 5])
    }
}

/// O outro lado da ponte: o compromisso que nasce do editor leva mesmo a
/// agenda e o aviso que a preferência escolheu.
@Suite("Os padrões no compromisso criado")
@MainActor
struct AgendaDefaultsReachTheItemTests {
    private let minha = Account(
        id: "minha", address: "marcos@okamiops.com", displayName: "Marcos",
        provider: .imap, host: "okamiops",
        tintLightHex: "#3E6FA8", tintDarkHex: "#7BA8D9"
    )
    private let outra = Account(
        id: "outra", address: "contato@okami.dev", displayName: "Okami",
        provider: .imap, host: "okami",
        tintLightHex: "#d98b2b", tintDarkHex: "#d98b2b"
    )

    private func store() async -> MailStore {
        let source = InMemoryMailSource(accounts: [minha, outra], messages: [], agenda: [])
        let store = MailStore(
            source: source, agendaPort: AgendaEmMemoria(),
            agendaReferenceDay: { Fixtures.today }
        )
        await store.load()
        return store
    }

    /// A preferência ganha de `stampedForMailbox`: o compromisso é da conta
    /// "minha", mas nasce na agenda que a pessoa escolheu — a da "outra".
    @Test("A agenda padrão vence o calendário da conta, com nome e cor")
    func agendaPadraoVence() async throws {
        let store = await store()
        let escolhida = ConnectedCalendar.mailboxID(forAccountID: outra.id)

        let criado = try #require(store.addManualAgendaItem(
            title: "Revisão",
            startMinute: 9 * 60, endMinute: 10 * 60,
            dayOffset: 0, accountID: minha.id,
            calendarID: escolhida,
            alert: .minutes(15)
        ))

        #expect(criado.calendarID == escolhida)
        #expect(criado.calendarTitle == outra.address)
        #expect(criado.calendarColorHex == outra.tintLightHex)
        #expect(criado.detail?.notice == CalendarAlert.minutes(15).notice)
        #expect(CalendarAlert.fromNotice(criado.detail?.notice) == .minutes(15))
    }

    @Test("Sem agenda padrão, continua caindo no calendário da própria conta")
    func semPadraoContinuaComoAntes() async throws {
        let store = await store()
        let criado = try #require(store.addManualAgendaItem(
            title: "Revisão",
            startMinute: 9 * 60, endMinute: 10 * 60,
            dayOffset: 0, accountID: minha.id
        ))
        #expect(criado.calendarID == ConnectedCalendar.mailboxID(forAccountID: minha.id))
        #expect(CalendarAlert.fromNotice(criado.detail?.notice) == CalendarAlert.none)
    }

    /// Um id que não existe mais não pode criar um compromisso órfão.
    @Test("Agenda padrão apagada é ignorada")
    func agendaSumidaEhIgnorada() async throws {
        let store = await store()
        let criado = try #require(store.addManualAgendaItem(
            title: "Revisão",
            startMinute: 9 * 60, endMinute: 10 * 60,
            dayOffset: 0, accountID: minha.id,
            calendarID: "caldav.conta-que-nao-existe.https://exemplo/x"
        ))
        #expect(criado.calendarID == ConnectedCalendar.mailboxID(forAccountID: minha.id))
    }
}

/// A linha de um serviço de reunião: o que ela oferece em cada estado.
@Suite("As salas de reunião da aba Agendas")
@MainActor
struct MeetingConnectionsTests {

    /// A regra do desenho, e a razão de `MeetingRoomAction` existir: sem o
    /// client ID no build, a linha **não** mostra Conectar.
    @Test("Sem client ID não há botão Conectar")
    func semClientIDNaoOfereceConectar() {
        let connections = MeetingConnections(connectors: [
            StubMeetingConnector(service: .zoom, isAvailable: false)
        ])
        #expect(connections.state(of: .zoom) == .unavailable)
        #expect(MeetingRoomAction(connections.state(of: .zoom)) == MeetingRoomAction.none)
        #expect(connections.state(of: .zoom).label == L10n.tr("ainda não disponível neste build"))

        // E um serviço sem conector nenhum se comporta igual.
        #expect(connections.state(of: .teams) == .unavailable)
        #expect(MeetingRoomAction(connections.state(of: .teams)) == MeetingRoomAction.none)
    }

    @Test("Conectar não faz nada num serviço que este build não tem")
    func conectarEhInerteSemClientID() {
        let connections = MeetingConnections(connectors: [
            StubMeetingConnector(service: .zoom, isAvailable: false)
        ])
        connections.connect(.zoom)
        #expect(connections.state(of: .zoom) == .unavailable)
    }

    @Test("Com client ID, a linha oferece Conectar e depois Desconectar")
    func cicloCompleto() async {
        let connections = MeetingConnections(connectors: [
            StubMeetingConnector(service: .zoom, account: "pessoa@exemplo.com")
        ])
        #expect(MeetingRoomAction(connections.state(of: .zoom)) == .connect)

        connections.connect(.zoom)
        for _ in 0..<200 where !connections.state(of: .zoom).isConnected {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(connections.state(of: .zoom) == .connected("pessoa@exemplo.com"))
        #expect(MeetingRoomAction(connections.state(of: .zoom)) == .disconnect)

        connections.disconnect(.zoom)
        #expect(MeetingRoomAction(connections.state(of: .zoom)) == .connect)
    }

    @Test("Esperando no navegador, a linha oferece Cancelar e Abrir de novo")
    func esperandoNoNavegador() async {
        let connections = MeetingConnections(connectors: [
            StubMeetingConnector(service: .zoho, hangs: true)
        ])
        connections.connect(.zoho)
        #expect(connections.state(of: .zoho) == .waitingInBrowser)
        #expect(MeetingRoomAction(connections.state(of: .zoho)) == .waiting)

        connections.cancel(.zoho)
        #expect(connections.state(of: .zoho) == .disconnected)
    }

    @Test("Dá para conectar várias contas e desconectar só uma")
    func variasContasNoMesmoServico() async {
        let conector = ContasDeReuniao()
        let connections = MeetingConnections(connectors: [conector])

        connections.connect(.zoom)
        for _ in 0..<200 where connections.linking.contains(.zoom) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        connections.connect(.zoom)
        for _ in 0..<200 where connections.linking.contains(.zoom) {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(connections.accounts(of: .zoom) == ["p1@x.com", "p2@x.com"])
        #expect(connections.state(of: .zoom) == .connected("p1@x.com"))

        connections.disconnect(.zoom, account: "p1@x.com")
        #expect(connections.accounts(of: .zoom) == ["p2@x.com"])
        #expect(connections.state(of: .zoom) == .connected("p2@x.com"))
        for _ in 0..<200 where conector.stored != ["p2@x.com"] {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(conector.stored == ["p2@x.com"])
    }
}

/// Guarda cada login, em vez de substituir o anterior.
@MainActor
private final class ContasDeReuniao: MeetingConnector {
    let service: MeetingService = .zoom
    var isAvailable: Bool = true
    var stored: [String] = []
    private var proxima = 0

    func connect() async throws -> String {
        proxima += 1
        let email = "p\(proxima)@x.com"
        stored.append(email)
        return email
    }

    func cancel() {}

    func disconnect() async { stored.removeAll() }

    func currentAccount() async -> String? { stored.first }

    func accounts() async -> [String] { stored }

    func disconnect(account: String) async {
        stored.removeAll { $0.caseInsensitiveCompare(account) == .orderedSame }
    }
}

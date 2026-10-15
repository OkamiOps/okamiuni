import AppKit
import Foundation
import NIOPosix
import SwiftUI
import Testing
import UNICore
import UNIDesign
import UNISync
@testable import UNIShell

/// Uma agenda de mentira: devolve calendários e um estado de permissão
/// escolhidos pelo caso, sem tocar no EventKit da máquina.
///
/// É o que faz a aba Agendas ter o que desenhar no retrato. Um `MailStore`
/// sem `calendarSync` nunca publica calendário nenhum, e a coluna da esquerda
/// sairia vazia — provando só que a página abre.
final class AgendaDeMentira: CalendarSyncing, @unchecked Sendable {
    private let lista: [ConnectedCalendar]
    private let estado: CalendarAvailability

    init(_ lista: [ConnectedCalendar], estado: CalendarAvailability) {
        self.lista = lista
        self.estado = estado
    }

    func availability() async -> CalendarAvailability { estado }
    func calendars() async -> [ConnectedCalendar] { lista }
    func synchronize(referenceDay: Date, requestAuthorization: Bool) async throws -> [AgendaItem] { [] }
    func save(_ item: AgendaItem, referenceDay: Date) async throws {}
    func remove(id: String, referenceDay: Date) async throws {}
}

/// Os quadros da aba **Agendas**, de `ConfigAgendas.dc.html`: a principal nos
/// três acabamentos, o aviso de permissão e a folha de conectar.
///
/// Nenhum caso abre janela visível, sintetiza clique nem toca na rede.
@Suite("Os quadros de Agendas", .serialized)
@MainActor
struct ConfigAgendasRenderTests {
    private let artboard = CGSize(width: 1_280, height: 800)
    private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A aba Agendas desenha as fontes, os padrões e as salas nos três acabamentos")
    func principal() async throws {
        for (tema, sufixo) in [
            (Theme.vidroNoite, "escuro"), (Theme.vidro, "claro"), (Theme.okami, "classico"),
        ] {
            let cena = try await scene(authorized: true)
            let image = try #require(Render.snapshot(
                window(cena),
                named: "Agendas-principal-\(sufixo)",
                size: artboard,
                theme: tema
            ))
            #expect(image.pixelsWide == Int(artboard.width))
            #expect(image.pixelsHigh == Int(artboard.height))

            // Os interruptores ligados são a única superfície de acento cheio
            // na coluna da esquerda: cinco calhas de 38×22.
            let esquerda = CGRect(x: 300, y: 130, width: 460, height: 560)
            #expect(
                pixels(image, matching: tema.accent, in: esquerda, tolerance: 0.12) > 700,
                "os interruptores de mostrar/ocultar não foram desenhados"
            )

            // E os dois cartões da direita, com os padrões e as salas.
            let direita = CGRect(x: 790, y: 130, width: 460, height: 580)
            #expect(
                pixels(image, matching: tema.glassCard, in: direita, tolerance: 0.06) > 20_000,
                "os cartões de Padrões e Salas de reunião não foram desenhados"
            )
        }
    }

    /// **A prova de que um serviço sem client ID não oferece Conectar.**
    ///
    /// No retrato não há `MeetingConnections` nenhuma, que é exatamente o
    /// estado de um build sem `Config/Meetings.xcconfig`: os quatro serviços
    /// ficam em `.unavailable`. Se a linha desenhasse "Conectar" assim mesmo,
    /// seriam quatro botões de acento cheio na faixa das salas.
    @Test("Sem client ID, a faixa das salas não tem botão de acento")
    func salaSemClientIDNaoMostraConectar() async throws {
        let cena = try await scene(authorized: true)
        let image = try #require(Render.snapshot(
            window(cena),
            named: "Agendas-salas-sem-id-claro",
            size: artboard,
            theme: .vidro
        ))
        for service in MeetingService.allCases {
            let estado = MeetingConnections(connectors: []).state(of: service)
            #expect(estado == .unavailable)
            #expect(MeetingRoomAction(estado) == MeetingRoomAction.none)
        }
        // A faixa das quatro linhas de serviço, abaixo de "Sala padrão".
        let salas = CGRect(x: 790, y: 500, width: 460, height: 210)
        #expect(
            pixels(image, matching: Theme.vidro.accent, in: salas, tolerance: 0.1) < 300,
            "apareceu um botão de acento numa sala que este build não tem"
        )
    }

    /// O build que vai para os clientes: o Meet existe (o app é registrado no
    /// Google) e Zoom, Teams e Zoho não. Só o Meet aparece — nem linha, nem
    /// opção de sala padrão para os outros.
    @Test("Só o Meet aparece quando os outros serviços não estão no build")
    func soMeet() async throws {
        let cena = try await scene(authorized: true)
        let connections = MeetingConnections(connectors: [
            StubMeetingConnector(service: .meet, account: "marcos@gmail.com"),
            StubMeetingConnector(service: .zoom, isAvailable: false),
            StubMeetingConnector(service: .teams, isAvailable: false),
            StubMeetingConnector(service: .zoho, isAvailable: false),
        ])
        await connections.refresh()
        #expect(connections.state(of: .meet).isConnected)
        for service in [MeetingService.zoom, .teams, .zoho] {
            #expect(connections.state(of: service) == .unavailable)
        }
        _ = try #require(Render.snapshot(
            window(cena, connections: connections),
            named: "Agendas-so-meet-escuro",
            size: artboard,
            theme: .vidroNoite
        ))
    }

    @Test("Sem permissão do macOS, o aviso toma o lugar das agendas do Mac")
    func semPermissao() async throws {
        let cena = try await scene(authorized: false)
        let image = try #require(Render.snapshot(
            window(cena),
            named: "Agendas-sem-permissao-claro",
            size: artboard,
            theme: .vidro
        ))
        #expect(image.pixelsWide == Int(artboard.width))
        // "Abrir os Ajustes do Sistema" é a única superfície de acento cheio
        // da coluna da esquerda — nenhum interruptor do Mac sobrou para
        // pintá-la de acento, porque não há agenda do Mac para mostrar.
        let bloco = CGRect(x: 300, y: 130, width: 460, height: 180)
        #expect(
            pixels(image, matching: Theme.vidro.accent, in: bloco, tolerance: 0.1) > 1_500,
            "o botão de abrir os Ajustes do Sistema não foi desenhado"
        )
        // E o triângulo de atenção, na tinta de aviso do tema.
        #expect(
            pixels(image, matching: Theme.vidro.warning, in: bloco, tolerance: 0.14) > 15,
            "o aviso de permissão não foi desenhado"
        )
        // E a navegação ganha o selo de 1.
        #expect(
            AgendaSources.needsCalendarPermission(cena.mail.calendarAvailability),
            "a disponibilidade de mentira não chegou ao MailStore"
        )
    }

    @Test("A folha de conectar mostra os quatro caminhos")
    func folhaDeConectar() async throws {
        let image = try #require(Render.snapshot(
            ConnectCalendarSheet(close: {}, addAccount: {})
                .frame(width: 560)
                .padding(40)
                .environment(\.configPalette, ConfigPalette(.vidro))
                .frame(width: 640, height: 480),
            named: "Agendas-conectar-claro",
            size: CGSize(width: 640, height: 480),
            theme: .vidro
        ))
        #expect(image.pixelsWide == 640)
        // Só o Google está aceso: um retângulo de `accentSoft` atrás da
        // primeira linha, e nenhum outro.
        #expect(
            image.pixels(matching: Theme.vidro.accentSoft) > 1_000,
            "a opção em destaque não foi desenhada"
        )
    }

    // MARK: A cena

    private struct Scene {
        let model: AccountsModel
        let mail: MailStore
        let preferences: CalendarPreferences
        let rooms: MeetingRoomSettingsStore
        let suite: String
    }

    private func scene(authorized: Bool) async throws -> Scene {
        let suite = "okamiuni.agendas-render.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let contas = [
            account(id: "gmail", address: "vantion@gmail.com", host: "gmail"),
            account(id: "zoho", address: "marcos@okamiops.com", host: "zoho"),
        ]
        let model = try await self.model(with: contas)

        let doMac: [ConnectedCalendar] = authorized ? [
            ConnectedCalendar(
                id: "EK-pessoal", title: "Pessoal", source: "iCloud",
                colorHex: "#e8575a", allowsModifications: true
            ),
            ConnectedCalendar(
                id: "EK-trabalho", title: "Trabalho", source: "Google",
                colorHex: "#2f7bd6", allowsModifications: true
            ),
            ConnectedCalendar(
                id: "EK-feriados", title: "Feriados do Brasil", source: "Outros",
                colorHex: "#8b8f9c", allowsModifications: false
            ),
        ] : []
        let agenda = AgendaDeMentira(
            doMac + [
                ConnectedCalendar(
                    id: ConnectedCalendar.calDAVID(
                        accountID: "zoho", calendarURL: "https://calendar.zoho.com/1"
                    ),
                    title: "Casa", source: "zoho",
                    colorHex: "#7c5cd6", allowsModifications: true
                ),
            ],
            estado: authorized ? .available : .authorizationRequired
        )

        let mail = MailStore(
            source: InMemoryMailSource.fixtures,
            calendarSync: agenda,
            calendarDefaults: defaults
        )
        await mail.load()
        await mail.refreshCalendar()
        // Duas agendas ocultas, como no desenho: a de só leitura do Mac e a
        // "Do email" do próprio app.
        mail.toggleCalendar(ConnectedCalendar.email.id)
        mail.toggleCalendar("EK-feriados")

        let preferences = CalendarPreferences(defaults: defaults)
        preferences.defaultCalendarID = "EK-pessoal"
        preferences.defaultRoom = .meet

        return Scene(
            model: model,
            mail: mail,
            preferences: preferences,
            rooms: MeetingRoomSettingsStore(defaults: defaults),
            suite: suite
        )
    }

    private func window(_ scene: Scene, connections: MeetingConnections? = nil) -> some View {
        AccountsWindow(
            model: scene.model,
            initialSection: .agenda,
            mailStore: scene.mail,
            meetingRooms: scene.rooms,
            calendarPreferences: scene.preferences,
            meetingConnections: connections
        )
    }

    private func account(
        id: String, address: String, host: String
    ) -> Account {
        Account(
            id: id, address: address, displayName: host.capitalized,
            provider: .imap, host: host,
            tintLightHex: "#6d63ff", tintDarkHex: "#a9a3ff",
            imap: ImapEndpoint(host: "imap.\(host).example", port: 993, security: .tls),
            state: .ativa,
            lastSyncedAt: createdAt
        )
    }

    private func model(with accounts: [Account]) async throws -> AccountsModel {
        let timestamp = createdAt
        let database = try SyncDatabase.temporary()
        try await database.pool.write { connection in
            for (index, account) in accounts.enumerated() {
                try AccountRecord(account, createdAt: timestamp.addingTimeInterval(Double(index)))
                    .insert(connection)
            }
        }
        let director = AccountDirector(
            database: database,
            secrets: InMemorySecretStore(),
            auth: nil,
            session: .shared,
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            imapConnect: { _, _ in throw SyncError.rede("não usado pelo retrato") },
            now: { timestamp }
        )
        let model = AccountsModel(director: director)
        let observer = Task { @MainActor in await model.start() }
        defer { observer.cancel() }
        for _ in 0..<150 {
            if model.statuses.count == accounts.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.statuses.count == accounts.count, "o banco temporário não publicou as contas")
        return model
    }

    /// O mesmo contador de `ConfigRenderTests`, restrito a um retângulo.
    private func pixels(
        _ image: NSBitmapImageRep,
        matching token: TokenColor,
        in rect: CGRect,
        tolerance: Double = 0.03
    ) -> Int {
        guard let wanted = token.nsColor.usingColorSpace(.sRGB) else { return 0 }
        let minX = max(0, Int(rect.minX))
        let maxX = min(image.pixelsWide, Int(rect.maxX))
        let minY = max(0, Int(rect.minY))
        let maxY = min(image.pixelsHigh, Int(rect.maxY))
        guard minX < maxX, minY < maxY else { return 0 }
        var count = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.9 else { continue }
                if abs(color.redComponent - wanted.redComponent) < tolerance,
                   abs(color.greenComponent - wanted.greenComponent) < tolerance,
                   abs(color.blueComponent - wanted.blueComponent) < tolerance {
                    count += 1
                }
            }
        }
        return count
    }
}

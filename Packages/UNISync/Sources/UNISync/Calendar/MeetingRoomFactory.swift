import Foundation
import Observation
import UNICore

/// Cria uma sala **nova** por compromisso. Meet usa o OAuth Google da caixa;
/// Zoom, Teams e Zoho usam a API de cada um quando a pessoa conectou em
/// Ajustes. Nunca devolve um link permanente.
@MainActor
@Observable
public final class MeetingRoomFactory: @unchecked Sendable {
    private let google: GoogleAuth?
    private let session: URLSession
    private let rooms: MeetingRoomSettingsStore
    /// `true` = Meet já autorizado nesta caixa; `false` = falta consentimento.
    /// Ausente = ainda não consultou. O botão de reconectar só aparece no `false`.
    public private(set) var meetAccess: [String: Bool] = [:]

    public init(
        google: GoogleAuth? = nil,
        session: URLSession = .shared,
        rooms: MeetingRoomSettingsStore = MeetingRoomSettingsStore()
    ) {
        self.google = google
        self.session = session
        self.rooms = rooms
    }

    public func canMint(
        _ service: MeetingService, account: Account, accounts: [Account] = []
    ) -> Bool {
        switch service {
        case .meet:
            google != nil && MeetingGoogleAccount.resolve(for: account, among: accounts) != nil
        case .zoom, .teams, .zoho:
            rooms.isConnected(service)
        }
    }

    public func hasMeetAccess(accountID: String) -> Bool? {
        meetAccess[accountID]
    }

    /// Completa `meetAccess` a partir do token (ou do tokeninfo, se o cofre
    /// ainda não gravou os escopos). Não mostra o botão enquanto não souber.
    public func refreshMeetAccess(accountID: String) async {
        guard let google else {
            meetAccess[accountID] = false
            return
        }
        if let known = await google.hasMeetAccess(for: accountID) {
            meetAccess[accountID] = known
        }
    }

    /// Abre o consentimento do Google de novo — só quando o Meet ainda não
    /// está no token.
    public func reconnectGoogle(accountID: String, loginHint: String?) async throws {
        guard let google else { throw MeetingRoomError.needsGoogle }
        let tokens = try await google.connect(accountID: accountID, loginHint: loginHint)
        if tokens.canCreateMeet {
            meetAccess[accountID] = true
        } else if let known = await google.hasMeetAccess(for: accountID) {
            meetAccess[accountID] = known
        } else {
            meetAccess[accountID] = false
        }
    }

    public func mint(_ request: MeetingRoomRequest) async throws -> MeetingMint {
        switch request.service {
        case .meet:
            return try await mintMeet(request)
        case .zoom:
            let link = try await ZoomMeetingClient(session: session, connection: connected(.zoom))
                .create(request)
            return MeetingMint(link: link)
        case .teams:
            let link = try await TeamsMeetingClient(session: session, connection: connected(.teams))
                .create(request)
            return MeetingMint(link: link)
        case .zoho:
            let link = try await ZohoMeetingClient(session: session, connection: connected(.zoho))
                .create(request)
            return MeetingMint(link: link)
        }
    }

    public func deleteGoogleMeet(
        accountID: String, eventID: String?, hangoutLink: String?, start: Date
    ) async {
        guard let google else { return }
        let client = GoogleMeetClient(
            session: session,
            accessToken: { try await google.accessToken(for: accountID) }
        )
        do {
            let id = try await client.resolveEventID(
                eventID: eventID, hangoutLink: hangoutLink, start: start
            )
            guard let id else { return }
            try await client.deleteEvent(id)
        } catch {
            return
        }
    }

    private func connected(_ service: MeetingService) throws -> MeetingServiceConnection {
        let connection = rooms.connection(for: service)
        guard connection.isComplete else { throw MeetingRoomError.notConnected(service) }
        return connection
    }

    private func mintMeet(_ request: MeetingRoomRequest) async throws -> MeetingMint {
        guard let google else { throw MeetingRoomError.needsGoogle }
        let oauthID = request.oauthAccountID
        let client = GoogleMeetClient(
            session: session,
            accessToken: { try await google.accessToken(for: oauthID) }
        )
        do {
            let minted = try await client.createConference(request)
            meetAccess[oauthID] = true
            return minted
        } catch MeetingRoomError.needsGoogle {
            meetAccess[oauthID] = false
            throw MeetingRoomError.needsGoogle
        }
    }
}

/// Meet no Gmail pessoal: um evento no Calendar com `conferenceData` cria
/// uma sala nova. A Meet REST (`spaces`) é de Workspace e nessa caixa
/// responde 403 mesmo com o escopo.
struct GoogleMeetClient: Sendable {
    let session: URLSession
    let accessToken: @Sendable () async throws -> String
    let baseURL: URL

    init(
        session: URLSession,
        accessToken: @Sendable @escaping () async throws -> String,
        baseURL: URL = URL(string: "https://www.googleapis.com/calendar/v3/")!
    ) {
        self.session = session
        self.accessToken = accessToken
        self.baseURL = baseURL
    }

    func createConference(_ request: MeetingRoomRequest) async throws -> MeetingMint {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var event: [String: Any] = [
            "summary": request.title,
            "start": [
                "dateTime": formatter.string(from: request.start),
                "timeZone": TimeZone.current.identifier,
            ],
            "end": [
                "dateTime": formatter.string(from: request.end),
                "timeZone": TimeZone.current.identifier,
            ],
            "conferenceData": [
                "createRequest": [
                    "requestId": UUID().uuidString,
                    "conferenceSolutionKey": ["type": "hangoutsMeet"],
                ]
            ],
        ]
        if !request.attendees.isEmpty {
            event["attendees"] = request.attendees.map { ["email": $0.address] }
        }
        if let rrule = request.rrule, !rrule.isEmpty {
            event["recurrence"] = ["RRULE:\(rrule)"]
        }
        let body = try JSONSerialization.data(withJSONObject: event)
        struct Wire: Decodable {
            let id: String?
            let hangoutLink: String?
            struct Conference: Decodable {
                struct Entry: Decodable { let uri: String? }
                let entryPoints: [Entry]?
            }
            let conferenceData: Conference?
        }
        let wire: Wire = try await send(
            path: "calendars/primary/events",
            query: [URLQueryItem(name: "conferenceDataVersion", value: "1")],
            method: "POST",
            body: body
        )
        let uri = wire.hangoutLink
            ?? wire.conferenceData?.entryPoints?.compactMap(\.uri).first
        guard let uri, let link = MeetingLink.normalizado(uri) else {
            throw MeetingRoomError.failed("O Google Calendar não devolveu o link do Meet.")
        }
        return MeetingMint(link: link, googleEventID: wire.id)
    }

    func resolveEventID(eventID: String?, hangoutLink: String?, start: Date) async throws -> String? {
        if let eventID, !eventID.hasPrefix("manual-") { return eventID }
        guard let hangoutLink else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let from = start.addingTimeInterval(-3_600)
        let to = start.addingTimeInterval(86_400)
        struct List: Decodable {
            struct Item: Decodable { let id: String?; let hangoutLink: String? }
            let items: [Item]?
        }
        let list: List = try await get(
            path: "calendars/primary/events",
            query: [
                URLQueryItem(name: "timeMin", value: formatter.string(from: from)),
                URLQueryItem(name: "timeMax", value: formatter.string(from: to)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "maxResults", value: "25"),
            ]
        )
        return list.items?.first { item in
            guard let found = item.hangoutLink else { return false }
            return MeetingLink.normalizado(found) == MeetingLink.normalizado(hangoutLink)
        }?.id
    }

    func deleteEvent(_ id: String) async throws {
        _ = try await raw(
            path: "calendars/primary/events/\(id)",
            query: [],
            method: "DELETE",
            body: nil
        )
    }

    private func get<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        try await send(path: path, query: query, method: "GET", body: nil)
    }

    private func send<T: Decodable>(
        path: String, query: [URLQueryItem], method: String, body: Data?
    ) async throws -> T {
        let dados = try await raw(path: path, query: query, method: method, body: body)
        if dados.isEmpty {
            throw MeetingRoomError.failed("O Google Calendar respondeu vazio.")
        }
        do {
            return try JSONDecoder().decode(T.self, from: dados)
        } catch {
            throw MeetingRoomError.failed("O Google Calendar devolveu um JSON que não reconhecemos.")
        }
    }

    private func raw(
        path: String, query: [URLQueryItem], method: String, body: Data?
    ) async throws -> Data {
        guard let resolved = URL(string: path, relativeTo: baseURL) else {
            throw MeetingRoomError.failed("URL do Google Calendar inválida.")
        }
        var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (dados, resposta): (Data, URLResponse)
        do {
            (dados, resposta) = try await session.data(for: request)
        } catch let erro as URLError {
            throw MeetingRoomError.failed(erro.localizedDescription)
        }
        guard let http = resposta as? HTTPURLResponse else {
            throw MeetingRoomError.failed("O Google Calendar respondeu sem HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.apiError(status: http.statusCode, body: dados)
        }
        return dados
    }

    private static func apiError(status: Int, body: Data) -> MeetingRoomError {
        struct Wire: Decodable {
            struct Item: Decodable { let reason: String? }
            struct Detalhe: Decodable {
                let message: String?
                let status: String?
                let errors: [Item]?
            }
            let error: Detalhe?
        }
        let fio = try? JSONDecoder().decode(Wire.self, from: body)
        let razoes = Set((fio?.error?.errors ?? []).compactMap(\.reason))
        let statusNome = fio?.error?.status ?? ""
        if status == 401 { return .needsGoogle }
        if razoes.contains("insufficientPermissions")
            || razoes.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT")
        {
            return .needsGoogle
        }
        if razoes.contains("accessNotConfigured") {
            return .failed(
                "Ative a API Google Calendar no projeto OAuth (Google Cloud) e reconecte a caixa."
            )
        }
        let mensagem = fio?.error?.message ?? String(data: body, encoding: .utf8) ?? "sem detalhe"
        if status == 403 && statusNome == "PERMISSION_DENIED" {
            return .needsGoogle
        }
        return .failed("O Google Calendar respondeu \(status): \(mensagem)")
    }
}

struct ZoomMeetingClient: Sendable {
    let session: URLSession
    let connection: MeetingServiceConnection

    func create(_ request: MeetingRoomRequest) async throws -> String {
        let token = try await accessToken()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
        let start = formatter.string(from: request.start)
        let payload: [String: Any] = [
            "topic": request.title,
            "type": 2,
            "start_time": start,
            "duration": request.durationMinutes,
            "timezone": TimeZone.current.identifier,
            "settings": ["join_before_host": true],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var http = URLRequest(url: URL(string: "https://api.zoom.us/v2/users/me/meetings")!)
        http.httpMethod = "POST"
        http.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = body
        struct Wire: Decodable { let joinUrl: String?; let join_url: String? }
        let wire: Wire = try await decode(http, as: Wire.self, service: .zoom)
        let url = wire.joinUrl ?? wire.join_url
        guard let url, let link = MeetingLink.normalizado(url) else {
            throw MeetingRoomError.failed("O Zoom não devolveu o link da reunião.")
        }
        return link
    }

    private func accessToken() async throws -> String {
        var http = URLRequest(
            url: URL(string: "https://zoom.us/oauth/token?grant_type=account_credentials&account_id=\(connection.extra)")!
        )
        http.httpMethod = "POST"
        let basic = Data("\(connection.clientID):\(connection.clientSecret)".utf8).base64EncodedString()
        http.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        struct Wire: Decodable { let access_token: String }
        return try await decode(http, as: Wire.self, service: .zoom).access_token
    }
}

struct TeamsMeetingClient: Sendable {
    let session: URLSession
    let connection: MeetingServiceConnection

    func create(_ request: MeetingRoomRequest) async throws -> String {
        let token = try await accessToken()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload: [String: Any] = [
            "subject": request.title,
            "startDateTime": formatter.string(from: request.start),
            "endDateTime": formatter.string(from: request.end),
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var http = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/onlineMeetings")!)
        http.httpMethod = "POST"
        http.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = body
        struct Wire: Decodable { let joinWebUrl: String? }
        let url = try await decode(http, as: Wire.self, service: .teams).joinWebUrl
        guard let url, let link = MeetingLink.normalizado(url) else {
            throw MeetingRoomError.failed("O Teams não devolveu o link da reunião.")
        }
        return link
    }

    private func accessToken() async throws -> String {
        var http = URLRequest(
            url: URL(string: "https://login.microsoftonline.com/\(connection.extra)/oauth2/v2.0/token")!
        )
        http.httpMethod = "POST"
        http.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        http.httpBody = [
            "client_id": connection.clientID,
            "client_secret": connection.clientSecret,
            "grant_type": "client_credentials",
            "scope": "https://graph.microsoft.com/.default",
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        struct Wire: Decodable { let access_token: String }
        return try await decode(http, as: Wire.self, service: .teams).access_token
    }
}

struct ZohoMeetingClient: Sendable {
    let session: URLSession
    let connection: MeetingServiceConnection

    func create(_ request: MeetingRoomRequest) async throws -> String {
        let token = try await accessToken()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload: [String: Any] = [
            "session": [
                "topic": request.title,
                "agenda": request.title,
                "presenter": 1,
                "startTime": formatter.string(from: request.start),
                "duration": request.durationMinutes,
                "timezone": TimeZone.current.identifier,
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var http = URLRequest(url: URL(string: "https://meeting.zoho.com/api/v2/meetings")!)
        http.httpMethod = "POST"
        http.setValue("Zoho-oauthtoken \(token)", forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = body
        struct Wire: Decodable {
            struct Session: Decodable {
                let joinLink: String?
                let startLink: String?
            }
            let session: Session?
        }
        let session = try await decode(http, as: Wire.self, service: .zoho).session
        let url = session?.joinLink ?? session?.startLink
        guard let url, let link = MeetingLink.normalizado(url) else {
            throw MeetingRoomError.failed("O Zoho Meeting não devolveu o link da reunião.")
        }
        return link
    }

    private func accessToken() async throws -> String {
        var http = URLRequest(url: URL(string: "https://accounts.zoho.com/oauth/v2/token")!)
        http.httpMethod = "POST"
        http.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        http.httpBody = [
            "refresh_token": connection.extra,
            "client_id": connection.clientID,
            "client_secret": connection.clientSecret,
            "grant_type": "refresh_token",
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        struct Wire: Decodable { let access_token: String }
        return try await decode(http, as: Wire.self, service: .zoho).access_token
    }
}

private extension ZoomMeetingClient {
    func decode<T: Decodable>(_ request: URLRequest, as: T.Type, service: MeetingService) async throws -> T {
        try await MeetingHTTP.decode(request, session: session, as: T.self, service: service)
    }
}

private extension TeamsMeetingClient {
    func decode<T: Decodable>(_ request: URLRequest, as: T.Type, service: MeetingService) async throws -> T {
        try await MeetingHTTP.decode(request, session: session, as: T.self, service: service)
    }
}

private extension ZohoMeetingClient {
    func decode<T: Decodable>(_ request: URLRequest, as: T.Type, service: MeetingService) async throws -> T {
        try await MeetingHTTP.decode(request, session: session, as: T.self, service: service)
    }
}

enum MeetingHTTP {
    static func decode<T: Decodable>(
        _ request: URLRequest, session: URLSession, as: T.Type, service: MeetingService
    ) async throws -> T {
        let (dados, resposta): (Data, URLResponse)
        do {
            (dados, resposta) = try await session.data(for: request)
        } catch let erro as URLError {
            throw MeetingRoomError.failed(erro.localizedDescription)
        }
        guard let http = resposta as? HTTPURLResponse else {
            throw MeetingRoomError.failed("\(service.label) respondeu sem HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw MeetingRoomError.notConnected(service)
            }
            let mensagem = String(data: dados, encoding: .utf8) ?? "sem detalhe"
            throw MeetingRoomError.failed("\(service.label) respondeu \(http.statusCode): \(mensagem)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: dados)
        } catch {
            throw MeetingRoomError.failed("\(service.label) devolveu um JSON que não reconhecemos.")
        }
    }
}

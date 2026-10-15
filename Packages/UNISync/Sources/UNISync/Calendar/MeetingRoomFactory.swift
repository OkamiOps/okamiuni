import Foundation
import Observation
import UNICore

/// Cria uma sala **nova** por compromisso. Nunca devolve um link permanente:
/// uma sala reaproveitada vira reunião eterna, com o título errado.
///
/// Os quatro serviços usam o **token da pessoa**, não credencial de servidor.
/// O Meet vem do OAuth Google da caixa de correio; Zoom, Teams e Zoho vêm do
/// login que a pessoa fez em Configurações ▸ Agendas, e quem entrega o token
/// é o `MeetingTokenSource` de cada conector.
///
/// **O que saiu daqui.** Até a versão anterior, Zoom, Teams e Zoho nasciam de
/// credencial digitada à mão numa tela de Ajustes: `account_credentials` do
/// Zoom, `client_credentials` do Teams e um refresh token colado do Zoho. Três
/// problemas, nessa ordem: a pessoa tinha de ir ao painel de desenvolvedor de
/// cada serviço para usar um aplicativo de e-mail; a sala nascia da conta de
/// *serviço* e não dela, então o convite vinha de um estranho; e os três
/// campos ficavam em `UserDefaults`, em texto plano. Agora é OAuth de usuário,
/// e o token mora no Keychain.
@MainActor
@Observable
public final class MeetingRoomFactory: @unchecked Sendable {
    private let google: GoogleAuth?
    private let session: URLSession
    /// Um por serviço conectável (Zoom, Teams, Zoho). Ausente = este build não
    /// tem o conector, e `canMint` devolve `false`.
    @ObservationIgnored
    private let tokens: [MeetingService: MeetingTokenSource]
    /// `true` = Meet já autorizado nesta caixa; `false` = falta consentimento.
    /// Ausente = ainda não consultou. O botão de reconectar só aparece no `false`.
    public private(set) var meetAccess: [String: Bool] = [:]

    public init(
        google: GoogleAuth? = nil,
        session: URLSession = .shared,
        tokens: [MeetingTokenSource] = []
    ) {
        self.google = google
        self.session = session
        self.tokens = Dictionary(
            tokens.map { ($0.service, $0) }, uniquingKeysWith: { primeiro, _ in primeiro }
        )
    }

    public func canMint(
        _ service: MeetingService, account: Account, accounts: [Account] = []
    ) -> Bool {
        switch service {
        case .meet:
            return google != nil && MeetingGoogleAccount.resolve(for: account, among: accounts) != nil
        case .zoom, .teams, .zoho:
            // Leitura síncrona do cofre: `SecretStore` é síncrono de
            // propósito, e a tela pergunta isto antes de desenhar o botão.
            return tokens[service]?.isConnected == true
        }
    }

    /// A conta conectada de um serviço, para a tela mostrar de quem a sala
    /// vai nascer. `nil` quando não há conexão.
    public func connectedAccount(_ service: MeetingService) -> String? {
        tokens[service]?.account
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
            let fonte = try source(.zoom)
            let link = try await ZoomMeetingClient(
                session: session, accessToken: { try await fonte.accessToken() }
            ).create(request)
            return MeetingMint(link: link)
        case .teams:
            let fonte = try source(.teams)
            let link = try await TeamsMeetingClient(
                session: session, accessToken: { try await fonte.accessToken() }
            ).create(request)
            return MeetingMint(link: link)
        case .zoho:
            return MeetingMint(link: try await mintZoho(request))
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

    private func source(_ service: MeetingService) throws -> MeetingTokenSource {
        guard let fonte = tokens[service], fonte.isConnected else {
            throw MeetingRoomError.notConnected(service)
        }
        return fonte
    }

    /// O Zoho precisa de duas coisas que os outros não pedem: o data center
    /// onde a conta mora e o `zsoid` da organização, que entra no caminho.
    /// Os dois foram gravados no login; o `zsoid` é buscado aqui quando
    /// faltar, para uma conexão antiga não ficar inútil.
    private func mintZoho(_ request: MeetingRoomRequest) async throws -> String {
        let fonte = try source(.zoho)
        guard let guardados = fonte.tokens,
              let servidor = guardados.accountsServer,
              let base = ZohoDataCenter.meetingAPIBase(accountsServer: servidor)
        else { throw MeetingRoomError.notConnected(.zoho) }

        var zsoid = guardados.zsoid
        if zsoid == nil {
            let token = try await fonte.accessToken()
            let usuario = try await ZohoUserClient(session: session, apiBase: base)
                .me(accessToken: token)
            zsoid = usuario.zsoid
            var atualizados = guardados
            atualizados.zsoid = usuario.zsoid
            atualizados.account = atualizados.account ?? usuario.email
            try? fonte.save(atualizados)
        }
        guard let zsoid else { throw MeetingRoomError.notConnected(.zoho) }
        return try await ZohoMeetingClient(
            session: session,
            apiBase: base,
            zsoid: zsoid,
            accessToken: { try await fonte.accessToken() }
        ).create(request)
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
            throw MeetingRoomError.failed(
                L10n.tr("O \(service.label) respondeu sem HTTP.")
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                // Token morto ou revogado: só reconectar resolve.
                throw MeetingRoomError.notConnected(service)
            }
            let mensagem = String(data: dados, encoding: .utf8)?.nonEmptyDetail
                ?? L10n.tr("sem detalhe")
            throw MeetingRoomError.failed(
                L10n.tr("O \(service.label) respondeu \(String(http.statusCode)): \(mensagem)")
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: dados)
        } catch {
            throw MeetingRoomError.failed(
                L10n.tr("O \(service.label) devolveu um JSON que não reconhecemos.")
            )
        }
    }
}

extension String {
    /// O corpo de erro do servidor, cortado: um HTML de 40 kB numa caixa de
    /// alerta não ajuda ninguém, e o começo dele já diz o que houve.
    var nonEmptyDetail: String? {
        let limpo = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty else { return nil }
        return limpo.count > 400 ? String(limpo.prefix(400)) + "…" : limpo
    }
}

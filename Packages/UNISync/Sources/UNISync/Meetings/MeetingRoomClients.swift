import Foundation
import UNICore

/// Cria a reunião no Zoom com o token **da pessoa**.
///
/// `POST /v2/users/me/meetings`, `type: 2` (reunião agendada, não recorrente
/// nem instantânea). `users/me` é quem o token representa: a sala nasce na
/// conta de quem conectou, e é o nome dela que aparece no convite.
struct ZoomMeetingClient: Sendable {
    let session: URLSession
    let accessToken: @Sendable () async throws -> String
    var apiBase: URL = URL(string: "https://api.zoom.us/v2/")!

    func create(_ request: MeetingRoomRequest) async throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
        let payload: [String: Any] = [
            "topic": request.title,
            "type": 2,
            "start_time": formatter.string(from: request.start),
            "duration": request.durationMinutes,
            "timezone": TimeZone.current.identifier,
            "settings": ["join_before_host": true],
        ]
        var http = URLRequest(url: URL(string: "users/me/meetings", relativeTo: apiBase)!)
        http.httpMethod = "POST"
        http.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        http.httpBody = try JSONSerialization.data(withJSONObject: payload)

        struct Wire: Decodable {
            let join_url: String?
            let joinUrl: String?
        }
        let fio = try await MeetingHTTP.decode(
            http, session: session, as: Wire.self, service: .zoom
        )
        guard let bruto = fio.join_url ?? fio.joinUrl,
              let link = MeetingLink.normalizado(bruto)
        else {
            throw MeetingRoomError.failed(
                L10n.tr("O Zoom não devolveu o link da reunião.")
            )
        }
        return link
    }
}

/// Cria a reunião no Teams com o token **da pessoa**, por dois caminhos.
///
/// **Primeiro `POST /me/onlineMeetings`.** É o caminho certo, e o único que
/// devolve uma reunião do Teams de verdade — com lobby, gravação e o resto.
/// Ele só existe para conta de **trabalho ou escola**.
///
/// **Depois `POST /me/events` com `isOnlineMeeting: true`.** Conta pessoal
/// Microsoft (MSA) não tem `/me/onlineMeetings`: responde 403 ou 404, e
/// desistir ali deixaria metade das pessoas sem sala. O evento do calendário
/// com `isOnlineMeeting` liga a reunião online que a conta tiver, e o link sai
/// em `onlineMeeting.joinUrl`.
///
/// **Sem `onlineMeetingProvider`.** Mandar `teamsForBusiness` numa conta
/// pessoal faz o Graph recusar o evento inteiro; omitir deixa o Graph escolher
/// o provedor que a conta tem. É de propósito, não esquecimento.
///
/// Se nem o segundo caminho trouxer link, a chamada **falha dizendo isso**.
/// Nunca devolve sala sem link: um compromisso com botão "Entrar" que não
/// entra em nada é pior que um compromisso sem botão.
struct TeamsMeetingClient: Sendable {
    let session: URLSession
    let accessToken: @Sendable () async throws -> String
    var graphBase: URL = URL(string: "https://graph.microsoft.com/v1.0/")!

    func create(_ request: MeetingRoomRequest) async throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let token = try await accessToken()

        do {
            return try await createOnlineMeeting(request, token: token, formatter: formatter)
        } catch let erro as MeetingRoomError {
            // Qualquer recusa do caminho de trabalho vira tentativa pelo
            // calendário: 403 e 404 são o que a conta pessoal devolve, e um
            // 400 por "resource not found for the segment" também aparece.
            if case .failed = erro {
                return try await createCalendarMeeting(request, token: token, formatter: formatter)
            }
            if case .notConnected = erro {
                return try await createCalendarMeeting(request, token: token, formatter: formatter)
            }
            throw erro
        }
    }

    private func createOnlineMeeting(
        _ request: MeetingRoomRequest, token: String, formatter: ISO8601DateFormatter
    ) async throws -> String {
        let payload: [String: Any] = [
            "subject": request.title,
            "startDateTime": formatter.string(from: request.start),
            "endDateTime": formatter.string(from: request.end),
        ]
        var http = URLRequest(url: URL(string: "me/onlineMeetings", relativeTo: graphBase)!)
        http.httpMethod = "POST"
        http.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        http.httpBody = try JSONSerialization.data(withJSONObject: payload)

        struct Wire: Decodable {
            let joinWebUrl: String?
            let joinUrl: String?
        }
        let fio = try await MeetingHTTP.decode(
            http, session: session, as: Wire.self, service: .teams
        )
        guard let bruto = fio.joinWebUrl ?? fio.joinUrl,
              let link = MeetingLink.normalizado(bruto)
        else {
            throw MeetingRoomError.failed(
                L10n.tr("O Microsoft Teams respondeu sem link de entrada.")
            )
        }
        return link
    }

    private func createCalendarMeeting(
        _ request: MeetingRoomRequest, token: String, formatter: ISO8601DateFormatter
    ) async throws -> String {
        var evento: [String: Any] = [
            "subject": request.title,
            "isOnlineMeeting": true,
            "start": [
                "dateTime": formatter.string(from: request.start),
                "timeZone": TimeZone.current.identifier,
            ],
            "end": [
                "dateTime": formatter.string(from: request.end),
                "timeZone": TimeZone.current.identifier,
            ],
        ]
        if !request.attendees.isEmpty {
            evento["attendees"] = request.attendees.map { contato in
                ["emailAddress": ["address": contato.address], "type": "required"]
            }
        }
        var http = URLRequest(url: URL(string: "me/events", relativeTo: graphBase)!)
        http.httpMethod = "POST"
        http.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        http.httpBody = try JSONSerialization.data(withJSONObject: evento)

        struct Wire: Decodable {
            struct Online: Decodable { let joinUrl: String? }
            let onlineMeeting: Online?
            let onlineMeetingUrl: String?
        }
        let fio = try await MeetingHTTP.decode(
            http, session: session, as: Wire.self, service: .teams
        )
        guard let bruto = fio.onlineMeeting?.joinUrl ?? fio.onlineMeetingUrl,
              let link = MeetingLink.normalizado(bruto)
        else {
            throw MeetingRoomError.failed(
                L10n.tr(
                    "Esta conta Microsoft não cria reunião do Teams: o Graph aceitou o compromisso mas não devolveu link de entrada. Use outro serviço ou cole um link existente."
                )
            )
        }
        return link
    }
}

/// Cria a reunião no Zoho Meeting com o token **da pessoa**, no data center
/// dela.
///
/// `POST {meeting.zoho.<dc>}/api/v2/{zsoid}/sessions.json`. As duas partes
/// variáveis do caminho vêm do login: o host de `ZohoDataCenter` e o `zsoid`
/// do `/api/v2/user.json`. Nenhuma das duas é adivinhável, e é por isso que o
/// conector as guarda junto com o token.
struct ZohoMeetingClient: Sendable {
    let session: URLSession
    let apiBase: URL
    let zsoid: String
    let accessToken: @Sendable () async throws -> String

    func create(_ request: MeetingRoomRequest) async throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload: [String: Any] = [
            "session": [
                "topic": request.title,
                "agenda": request.title,
                "startTime": formatter.string(from: request.start),
                "duration": request.durationMinutes,
                "timezone": TimeZone.current.identifier,
            ]
        ]
        var http = URLRequest(
            url: URL(string: "\(zsoid)/sessions.json", relativeTo: apiBase)!
        )
        http.httpMethod = "POST"
        http.setValue(
            "Zoho-oauthtoken \(try await accessToken())", forHTTPHeaderField: "Authorization"
        )
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        http.httpBody = try JSONSerialization.data(withJSONObject: payload)

        struct Wire: Decodable {
            struct Session: Decodable {
                let joinLink: String?
                let attendeeJoinLink: String?
                let startLink: String?
            }
            let session: Session?
        }
        let fio = try await MeetingHTTP.decode(
            http, session: session, as: Wire.self, service: .zoho
        )
        let bruto = fio.session?.joinLink
            ?? fio.session?.attendeeJoinLink
            ?? fio.session?.startLink
        guard let bruto, let link = MeetingLink.normalizado(bruto) else {
            throw MeetingRoomError.failed(
                L10n.tr("O Zoho Meeting não devolveu o link da reunião.")
            )
        }
        return link
    }
}

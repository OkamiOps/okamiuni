import Foundation
import UNICore

/// Requisição e resposta pequenas para que o protocolo CalDAV seja verificável
/// sem abrir a rede. O transporte é responsável por autenticar com o segredo
/// guardado no cofre do aplicativo; o cliente nunca recebe nem registra senha.
public struct CalDAVRequest: Sendable, Hashable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct CalDAVResponse: Sendable, Hashable {
    public let status: Int
    public let body: Data
    /// Transporte real deve preencher este valor quando a pilha HTTP tiver
    /// seguido um redirect; assim uma troca de host não passa despercebida.
    public let finalURL: URL?

    public init(status: Int, body: Data = Data(), finalURL: URL? = nil) {
        self.status = status
        self.body = body
        self.finalURL = finalURL
    }
}

public protocol CalDAVTransport: Sendable {
    func send(_ request: CalDAVRequest) async throws -> CalDAVResponse
}

public struct CalDAVCalendar: Sendable, Hashable, Identifiable {
    public let url: URL
    public let title: String
    public var id: String { url.absoluteString }
}

public struct CalDAVEvent: Sendable, Hashable, Identifiable {
    public let href: URL
    public let uid: String
    public let okamiID: String?
    public let title: String
    public let start: Date
    public let end: Date
    public let location: String?
    public let notes: String?
    public var id: String { href.absoluteString }
}

/// Descoberta, leitura por intervalo e escrita CalDAV. O construtor aceita só
/// HTTPS e `resolved` recusam hrefs que troquem de host. O transporte informa
/// a URL final caso a pilha HTTP tenha seguido redirect; uma troca de host
/// também é recusada, para que o servidor não redirecione agenda a outro
/// destino.
public struct CalDAVClient: Sendable {
    private let baseURL: URL
    private let transport: any CalDAVTransport

    public init(baseURL: URL, transport: any CalDAVTransport) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil else {
            throw SyncError.tls("CalDAV exige uma URL HTTPS com host")
        }
        self.baseURL = baseURL
        self.transport = transport
    }

    public func discoverCalendars() async throws -> [CalDAVCalendar] {
        let principal = try await xml(
            "PROPFIND", wellKnownURL(), depth: "0",
            "<d:propfind xmlns:d=\"DAV:\"><d:prop><d:current-user-principal/></d:prop></d:propfind>"
        )
        guard let principalHref = XML.values(named: "href", in: principal).first else {
            throw SyncError.resposta("O servidor CalDAV não informou o principal da conta.")
        }
        let principalURL = try resolved(principalHref, relativeTo: baseURL)
        let home = try await xml(
            "PROPFIND", principalURL, depth: "0",
            "<d:propfind xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\"><d:prop><c:calendar-home-set/></d:prop></d:propfind>"
        )
        guard let homeHref = XML.values(named: "href", in: home).first else {
            throw SyncError.resposta("O servidor CalDAV não informou onde ficam os calendários.")
        }
        let homeURL = try resolved(homeHref, relativeTo: principalURL)
        let collections = try await xml(
            "PROPFIND", homeURL, depth: "1",
            "<d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/></d:prop></d:propfind>"
        )
        let result = try XML.responses(in: collections).compactMap { response -> CalDAVCalendar? in
            guard response.localizedCaseInsensitiveContains("calendar"),
                  let href = XML.values(named: "href", in: response).first
            else { return nil }
            return CalDAVCalendar(
                url: try resolved(href, relativeTo: homeURL),
                title: XML.values(named: "displayname", in: response).first ?? "Calendário"
            )
        }
        guard !result.isEmpty else { throw SyncError.resposta("A conta CalDAV não ofereceu calendários.") }
        return result
    }

    public func events(
        in calendar: CalDAVCalendar, from start: Date, through end: Date
    ) async throws -> [CalDAVEvent] {
        let body = """
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop><c:calendar-data/></d:prop>
          <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"><c:time-range start="\(Self.utc(start))" end="\(Self.utc(end))"/></c:comp-filter></c:comp-filter></c:filter>
        </c:calendar-query>
        """
        let report = try await xml("REPORT", calendar.url, depth: "1", body)
        return try XML.responses(in: report).compactMap { response in
            guard let href = XML.values(named: "href", in: response).first,
                  let ics = XML.values(named: "calendar-data", in: response).first
            else { return nil }
            return try Self.event(from: ics, href: resolved(href, relativeTo: calendar.url))
        }
    }

    public func put(_ event: CalDAVEvent, in calendar: CalDAVCalendar) async throws {
        let target = try resolved(event.href.absoluteString, relativeTo: calendar.url)
        _ = try await request(CalDAVRequest(
            method: "PUT", url: target,
            headers: ["Content-Type": "text/calendar; charset=utf-8"],
            body: Data(Self.ics(event).utf8)
        ))
    }

    public func delete(_ event: CalDAVEvent) async throws {
        _ = try await request(CalDAVRequest(method: "DELETE", url: event.href))
    }

    private func xml(_ method: String, _ url: URL, depth: String, _ body: String) async throws -> String {
        let response = try await request(CalDAVRequest(
            method: method, url: url,
            headers: ["Depth": depth, "Content-Type": "application/xml; charset=utf-8"],
            body: Data(body.utf8)
        ))
        return String(data: response.body, encoding: .utf8) ?? ""
    }

    private func request(_ request: CalDAVRequest) async throws -> CalDAVResponse {
        guard request.url.scheme?.lowercased() == "https", request.url.host == baseURL.host else {
            throw SyncError.tls("CalDAV recusou URL fora do host HTTPS configurado")
        }
        let response: CalDAVResponse
        do { response = try await transport.send(request) }
        catch { throw SyncError.rede(error.localizedDescription) }
        if let finalURL = response.finalURL,
           finalURL.scheme?.lowercased() != "https" || finalURL.host != baseURL.host {
            throw SyncError.tls("CalDAV recusou redirect para outro host ou para uma URL insegura")
        }
        guard (200...299).contains(response.status) else {
            switch response.status {
            case 401: throw SyncError.autenticacao
            case 403: throw SyncError.autorizacaoRevogada
            case 429: throw SyncError.quota
            default: throw SyncError.servidor(
                codigo: response.status,
                mensagem: String(data: response.body, encoding: .utf8) ?? "CalDAV"
            )
            }
        }
        return response
    }

    private func wellKnownURL() -> URL {
        URL(string: "/.well-known/caldav", relativeTo: baseURL)!.absoluteURL
    }

    private func resolved(_ href: String, relativeTo url: URL) throws -> URL {
        guard let result = URL(string: href, relativeTo: url)?.absoluteURL,
              result.scheme?.lowercased() == "https", result.host == baseURL.host
        else { throw SyncError.tls("O servidor CalDAV apontou para outro host ou para uma URL insegura") }
        return result
    }

    private static func event(from text: String, href: URL) -> CalDAVEvent? {
        let lines = text.replacingOccurrences(of: "\r\n ", with: "").components(separatedBy: .newlines)
        guard let uid = value("UID", lines), let start = date(value("DTSTART", lines)) else { return nil }
        return CalDAVEvent(
            href: href, uid: uid, okamiID: value("X-OKAMIUNI-ID", lines),
            title: value("SUMMARY", lines) ?? "Sem título", start: start,
            end: date(value("DTEND", lines)) ?? start.addingTimeInterval(3_600),
            location: value("LOCATION", lines), notes: value("DESCRIPTION", lines)
        )
    }

    private static func ics(_ event: CalDAVEvent) -> String {
        ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//OkamiOps//OkamiUNI//PT", "BEGIN:VEVENT",
         "UID:\(event.uid)", "DTSTAMP:\(utc(Date()))", "DTSTART:\(utc(event.start))", "DTEND:\(utc(event.end))",
         "SUMMARY:\(escape(event.title))", event.okamiID.map { "X-OKAMIUNI-ID:\(escape($0))" },
         event.location.map { "LOCATION:\(escape($0))" }, event.notes.map { "DESCRIPTION:\(escape($0))" },
         "END:VEVENT", "END:VCALENDAR", ""].compactMap { $0 }.joined(separator: "\r\n")
    }

    private static func value(_ name: String, _ lines: [String]) -> String? {
        lines.first { $0.uppercased().hasPrefix(name + ":") || $0.uppercased().hasPrefix(name + ";") }
            .flatMap { $0.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) }
            .map { $0.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\,", with: ",") }
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = value.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss"
        return formatter.date(from: value)
    }

    private static func utc(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

private enum XML {
    static func values(named name: String, in text: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?is)<(?:[A-Za-z0-9_-]+:)?\(escaped)\\b[^>]*>(.*?)</(?:[A-Za-z0-9_-]+:)?\(escaped)\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    static func responses(in text: String) -> [String] { values(named: "response", in: text) }
}

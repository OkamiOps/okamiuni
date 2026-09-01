import Foundation

/// Os tokens de uma conta OAuth.
///
/// `expiresAt` é instante absoluto, não horário de parede — nenhum fuso
/// atravessa isto.
public struct OAuthTokens: Sendable, Hashable, Codable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    /// Escopos concedidos neste token. Vazio em tokens antigos — aí
    /// `GoogleAuth.hasMeetAccess` consulta o tokeninfo e completa o cofre.
    public let scopes: [String]

    enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, expiresAt, scopes
    }

    public init(
        accessToken: String, refreshToken: String, expiresAt: Date, scopes: [String] = []
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
    }

    /// Calendar `events` (Gmail pessoal) ou Meet Space (Workspace). Qualquer
    /// um dos dois permite criar sala nova.
    public var canCreateMeet: Bool {
        scopes.contains { scope in
            scope.contains("meetings.space.created")
                || scope.contains("auth/calendar.events")
                || scope.hasSuffix("/auth/calendar")
                || scope == "https://www.googleapis.com/auth/calendar"
        }
    }

    public static func parseScopes(_ raw: String?) -> [String] {
        (raw ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Vencido, com folga.
    ///
    /// A margem existe porque um token que morre em dez segundos já está morto
    /// para uma requisição que leva quinze: renovar antes é mais barato que
    /// descobrir o 401 no meio da carga inicial e refazer o lote.
    public func isExpired(at now: Date, margin: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(margin) >= expiresAt
    }
}

/// O que uma conta guarda no Keychain.
///
/// Duas formas porque são dois protocolos: IMAP autentica com senha de app,
/// Google com um par de tokens que se renova. Um `String` só serviria aos dois
/// e obrigaria quem lê a adivinhar qual é qual.
public enum Secret: Sendable, Hashable, Codable {
    case password(String)
    case oauth(OAuthTokens)
}

/// O cofre de segredos, por conta.
///
/// Protocolo, e não a implementação direta, por um motivo concreto: o Keychain
/// em ambiente de teste pede desbloqueio, exige binário assinado e deixa lixo
/// na keychain do usuário. Os testes de tudo que **usa** segredo rodam contra
/// `InMemorySecretStore`; o Keychain de verdade tem o teste dele, atrás de uma
/// marca de ambiente.
///
/// Síncrono de propósito: as chamadas do `Security.framework` são síncronas e
/// rápidas, e envolvê-las em `async` só acrescentaria pontos de suspensão sem
/// nada em troca.
public protocol SecretStore: Sendable {
    /// Guarda, sobrescrevendo o que houver para esta conta.
    func store(_ secret: Secret, for accountID: String) throws
    /// Nulo quando não há nada guardado — ausência não é erro.
    func secret(for accountID: String) throws -> Secret?
    /// Apagar o que não existe não lança: é o mesmo estado a que se queria
    /// chegar, como `MailStore.removeFromAgenda`.
    func remove(for accountID: String) throws
}

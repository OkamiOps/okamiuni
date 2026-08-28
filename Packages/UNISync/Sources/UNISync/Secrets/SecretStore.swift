import Foundation

/// Os tokens de uma conta OAuth.
///
/// `expiresAt` é instante absoluto, não horário de parede — nenhum fuso
/// atravessa isto.
public struct OAuthTokens: Sendable, Hashable, Codable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
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

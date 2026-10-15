import Foundation
import UNICore

/// O que o OkamiUNI guarda de um serviço de reunião depois do login da pessoa.
///
/// É o irmão de `OAuthTokens` para Zoom, Teams e Zoho, e carrega três coisas
/// que o Google não precisa:
///
/// - `account`: o e-mail que entrou. A aba Agendas mostra esta linha, e lê
///   daqui em vez de bater na API a cada abertura de janela.
/// - `accountsServer`: só o Zoho. O login devolve em qual data center a conta
///   mora (`accounts.zoho.eu`, `accounts.zohocloud.ca`…), e **a troca do
///   código, a renovação e a criação da sala têm de ir para lá**. Guardar o
///   servidor junto com o token é o que impede o app de renovar no `.com` um
///   token nascido no `.eu` e tomar `invalid_code` sem explicação.
/// - `zsoid`: só o Zoho. O caminho de criar sala é
///   `/api/v2/{zsoid}/sessions.json`; sem o identificador da organização não
///   há URL para onde postar.
public struct MeetingTokens: Sendable, Hashable, Codable {
    public var accessToken: String
    /// Ausente quando o serviço não devolveu um. Aí a conexão vale só até o
    /// access token vencer, e a pessoa reconecta — melhor que fingir que há
    /// o que renovar.
    public var refreshToken: String?
    public var expiresAt: Date
    public var account: String?
    public var accountsServer: String?
    public var zsoid: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date,
        account: String? = nil,
        accountsServer: String? = nil,
        zsoid: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.account = account
        self.accountsServer = accountsServer
        self.zsoid = zsoid
    }

    /// Vencido, com a mesma folga de `OAuthTokens`: um token que morre em dez
    /// segundos já está morto para uma requisição que leva quinze.
    public func isExpired(at now: Date, margin: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(margin) >= expiresAt
    }
}

/// O cofre dos tokens de reunião: um item de Keychain por serviço.
///
/// A chave é `meeting.<serviço>` e não o id de uma caixa de correio, porque a
/// conexão é do **aplicativo com o serviço**, não de um e-mail: a pessoa
/// conecta o Zoom uma vez e todo compromisso de qualquer caixa nasce com sala
/// dele. É o mesmo `SecretStore` das contas — o Keychain é o mesmo cofre, e
/// nenhum token de reunião passa pelo banco nem pelas preferências.
public struct MeetingTokenVault: Sendable {
    private let secrets: any SecretStore

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    public static func key(for service: MeetingService) -> String {
        "meeting.\(service.rawValue)"
    }

    public func load(_ service: MeetingService) -> MeetingTokens? {
        guard case .meeting(let tokens)? = try? secrets.secret(for: Self.key(for: service)) else {
            return nil
        }
        return tokens
    }

    public func save(_ tokens: MeetingTokens, for service: MeetingService) throws {
        try secrets.store(.meeting(tokens), for: Self.key(for: service))
    }

    public func clear(_ service: MeetingService) {
        try? secrets.remove(for: Self.key(for: service))
    }

    public func isConnected(_ service: MeetingService) -> Bool {
        load(service) != nil
    }
}

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

/// O cofre dos tokens de reunião.
///
/// Cada conta de um serviço tem a sua chave, `meeting.<serviço>.<e-mail>`.
/// A chave antiga `meeting.<serviço>` continua existindo: é a conta padrão
/// que `load` e `connectedAccount` já liam, e uma instalação que só tem essa
/// chave entra na lista na primeira leitura. O Keychain não lista chaves, então
/// os e-mails ficam num índice `meeting.<serviço>.roster`.
///
/// É o mesmo `SecretStore` das contas — o Keychain é o mesmo cofre, e nenhum
/// token de reunião passa pelo banco nem pelas preferências.
public struct MeetingTokenVault: Sendable {
    private let secrets: any SecretStore

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    public static func key(for service: MeetingService) -> String {
        "meeting.\(service.rawValue)"
    }

    static func rosterKey(for service: MeetingService) -> String {
        "meeting.\(service.rawValue).roster"
    }

    static func accountKey(_ service: MeetingService, slug: String) -> String {
        "meeting.\(service.rawValue).\(slug)"
    }

    static func slug(_ account: String) -> String {
        account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A conta padrão. Quem já gravava e lia uma conta só continua por aqui.
    public func load(_ service: MeetingService) -> MeetingTokens? {
        guard case .meeting(let tokens)? = try? secrets.secret(for: Self.key(for: service)) else {
            return nil
        }
        return tokens
    }

    /// O token da conta pedida. `nil` no argumento é a conta padrão.
    /// Uma conta que só existe na chave antiga ainda é encontrada.
    public func tokens(for service: MeetingService, account: String?) -> MeetingTokens? {
        if let email = account?.nonEmptyValue {
            let slug = Self.slug(email)
            if let slot = loadSlug(service, slug) { return slot }
            if let legacy = load(service), Self.slug(legacy.account ?? "") == slug {
                return legacy
            }
            return nil
        }
        return load(service)
    }

    /// Todas as contas deste serviço, na ordem em que foram conectadas.
    /// A chave antiga entra na lista se ainda não estiver no índice.
    public func accounts(_ service: MeetingService) -> [MeetingTokens] {
        var slugs = readRoster(service)
        var lista = slugs.compactMap { loadSlug(service, $0) }
        guard let legacy = load(service) else { return lista }
        guard let email = legacy.account?.nonEmptyValue else {
            return lista.isEmpty ? [legacy] : lista
        }
        let slug = Self.slug(email)
        guard !slugs.contains(slug) else { return lista }
        try? secrets.store(.meeting(legacy), for: Self.accountKey(service, slug: slug))
        slugs.insert(slug, at: 0)
        try? writeRoster(slugs, for: service)
        lista.insert(legacy, at: 0)
        return lista
    }

    public func save(_ tokens: MeetingTokens, for service: MeetingService) throws {
        if let email = tokens.account?.nonEmptyValue {
            let slug = Self.slug(email)
            try secrets.store(.meeting(tokens), for: Self.accountKey(service, slug: slug))
            var slugs = readRoster(service)
            if !slugs.contains(slug) {
                slugs.append(slug)
                try writeRoster(slugs, for: service)
            }
        }
        // A chave antiga recebe esta gravação também. `load` e a renovação
        // sem conta nomeada continuam vendo um token, e as outras contas
        // ficam nas chaves delas.
        try secrets.store(.meeting(tokens), for: Self.key(for: service))
    }

    public func clear(_ service: MeetingService) {
        for slug in readRoster(service) {
            try? secrets.remove(for: Self.accountKey(service, slug: slug))
        }
        try? secrets.remove(for: Self.rosterKey(for: service))
        try? secrets.remove(for: Self.key(for: service))
    }

    /// Tira uma conta. A padrão, se era esta, passa a ser a que sobrou.
    /// Sem e-mail, tira só a chave antiga — é o token gravado antes de haver
    /// conta nomeada.
    public func remove(_ service: MeetingService, account: String?) {
        if let email = account?.nonEmptyValue {
            let slug = Self.slug(email)
            try? secrets.remove(for: Self.accountKey(service, slug: slug))
            let slugs = readRoster(service).filter { $0 != slug }
            try? writeRoster(slugs, for: service)
            if let legacy = load(service), Self.slug(legacy.account ?? "") == slug {
                promote(service, slugs: slugs)
            }
            return
        }
        try? secrets.remove(for: Self.key(for: service))
        let slugs = readRoster(service)
        if !slugs.isEmpty {
            promote(service, slugs: slugs)
        }
    }

    public func isConnected(_ service: MeetingService) -> Bool {
        load(service) != nil || !readRoster(service).isEmpty
    }

    private func promote(_ service: MeetingService, slugs: [String]) {
        if let slug = slugs.first, let tokens = loadSlug(service, slug) {
            try? secrets.store(.meeting(tokens), for: Self.key(for: service))
        } else {
            try? secrets.remove(for: Self.key(for: service))
        }
    }

    private func loadSlug(_ service: MeetingService, _ slug: String) -> MeetingTokens? {
        guard case .meeting(let tokens)? = try? secrets.secret(for: Self.accountKey(service, slug: slug)) else {
            return nil
        }
        return tokens
    }

    private func readRoster(_ service: MeetingService) -> [String] {
        guard case .meetingRoster(let slugs)? = try? secrets.secret(for: Self.rosterKey(for: service)) else {
            return []
        }
        return slugs
    }

    private func writeRoster(_ slugs: [String], for service: MeetingService) throws {
        if slugs.isEmpty {
            try secrets.remove(for: Self.rosterKey(for: service))
            return
        }
        try secrets.store(.meetingRoster(slugs), for: Self.rosterKey(for: service))
    }
}

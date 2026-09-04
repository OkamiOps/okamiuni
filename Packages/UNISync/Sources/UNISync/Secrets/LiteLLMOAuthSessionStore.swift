import UNICore
import Foundation
import Security

/// Sessão de cliente do LiteLLM obtida pelo fluxo OAuth 2.0 Authorization
/// Code + PKCE. Access e refresh token ficam juntos no Keychain; as
/// preferências guardam somente o `credentialID` que seleciona esta entrada.
public struct LiteLLMOAuthSession: Codable, Sendable, Hashable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var clientID: String
    public var issuer: URL
    public var tokenEndpoint: URL
    public var revocationEndpoint: URL
    public var resource: URL
    public var userID: String?
    public var teamID: String?

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        clientID: String,
        issuer: URL,
        tokenEndpoint: URL,
        revocationEndpoint: URL,
        resource: URL,
        userID: String? = nil,
        teamID: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.clientID = clientID
        self.issuer = issuer
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.resource = resource
        self.userID = userID
        self.teamID = teamID
    }

    /// Renova um pouco antes do vencimento para não iniciar uma chamada de IA
    /// com um JWT que vai expirar enquanto o corpo do e-mail é processado.
    public func needsRefresh(at date: Date, leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(date) <= max(0, leeway)
    }
}

public protocol LiteLLMOAuthSessionStoring: Sendable {
    func store(_ session: LiteLLMOAuthSession, for credentialID: String) throws
    func session(for credentialID: String) throws -> LiteLLMOAuthSession?
    func containsSession(for credentialID: String) throws -> Bool
    func removeSession(for credentialID: String) throws
}

public extension LiteLLMOAuthSessionStoring {
    func containsSession(for credentialID: String) throws -> Bool {
        try session(for: credentialID) != nil
    }
}

public enum LiteLLMOAuthSessionStoreError: Error, Sendable, Equatable, LocalizedError {
    case unreadableKeychainValue
    case keychain(status: Int32)

    public var errorDescription: String? {
        switch self {
        case .unreadableKeychainValue:
            L10n.tr("O Keychain devolveu uma sessão OAuth do LiteLLM inválida.")
        case let .keychain(status):
            L10n.tr("Não foi possível acessar a sessão OAuth do LiteLLM no Keychain (código \(status)).")
        }
    }
}

/// Cofre exclusivo das sessões OAuth do proxy. Acessibilidade `ThisDeviceOnly`
/// impede que refresh tokens sejam restaurados em outro Mac por backup.
public struct KeychainLiteLLMOAuthSessionStore: LiteLLMOAuthSessionStoring, Sendable {
    private let service: String

    public init(service: String = "com.okamiops.okamiuni.litellm-oauth") {
        self.service = service
    }

    public func store(_ session: LiteLLMOAuthSession, for credentialID: String) throws {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        let data = try JSONEncoder().encode(session)

        let status = SecItemUpdate(
            query(credentialID) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        if status != errSecItemNotFound {
            throw LiteLLMOAuthSessionStoreError.keychain(status: Int32(status))
        }

        var insert = query(credentialID)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw LiteLLMOAuthSessionStoreError.keychain(status: Int32(added))
        }
    }

    public func session(for credentialID: String) throws -> LiteLLMOAuthSession? {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        var lookup = query(credentialID)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw LiteLLMOAuthSessionStoreError.keychain(status: Int32(status))
        }
        guard let data = item as? Data,
              let decoded = try? JSONDecoder().decode(LiteLLMOAuthSession.self, from: data)
        else {
            throw LiteLLMOAuthSessionStoreError.unreadableKeychainValue
        }
        return decoded
    }

    public func containsSession(for credentialID: String) throws -> Bool {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        var lookup = query(credentialID)
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = SecItemCopyMatching(lookup as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw LiteLLMOAuthSessionStoreError.keychain(status: Int32(status))
        }
        return true
    }

    public func removeSession(for credentialID: String) throws {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        let status = SecItemDelete(query(credentialID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LiteLLMOAuthSessionStoreError.keychain(status: Int32(status))
        }
    }

    private func query(_ credentialID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialID,
        ]
    }
}

public final class InMemoryLiteLLMOAuthSessionStore:
    LiteLLMOAuthSessionStoring, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [String: LiteLLMOAuthSession] = [:]

    public init() {}

    public func store(_ session: LiteLLMOAuthSession, for credentialID: String) throws {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        lock.lock()
        defer { lock.unlock() }
        storage[credentialID] = session
    }

    public func session(for credentialID: String) throws -> LiteLLMOAuthSession? {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        lock.lock()
        defer { lock.unlock() }
        return storage[credentialID]
    }

    public func containsSession(for credentialID: String) throws -> Bool {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        lock.lock()
        defer { lock.unlock() }
        return storage[credentialID] != nil
    }

    public func removeSession(for credentialID: String) throws {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: credentialID)
    }
}

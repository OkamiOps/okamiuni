import Foundation
import Security

/// Tokens de uma assinatura OAuth direta de provedor. As preferências de IA
/// guardam apenas o `credentialID`; esta estrutura inteira fica no Keychain
/// deste Mac e nunca deve ser serializada em `UserDefaults`, logs ou drafts.
public struct AssistantProviderOAuthSession: Codable, Sendable, Hashable {
    public var kind: AssistantProviderOAuthKind
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var tokenEndpoint: URL

    public init(
        kind: AssistantProviderOAuthKind,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        tokenEndpoint: URL
    ) {
        self.kind = kind
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenEndpoint = tokenEndpoint
    }

    public func needsRefresh(at date: Date) -> Bool {
        let leeway: TimeInterval = switch kind {
        case .codex: 120
        // As sessões xAI elegíveis são curtas. Renovar antes evita uma falha
        // no meio de uma resposta grande sem converter o refresh em polling.
        case .xAI: 3_600
        }
        return expiresAt.timeIntervalSince(date) <= leeway
    }
}

public protocol AssistantProviderOAuthSessionStoring: Sendable {
    func store(_ session: AssistantProviderOAuthSession, for credentialID: String) throws
    func session(for credentialID: String) throws -> AssistantProviderOAuthSession?
    func removeSession(for credentialID: String) throws
}

public enum AssistantProviderOAuthSessionStoreError: Error, Sendable, Equatable, LocalizedError {
    case unreadableKeychainValue
    case keychain(status: Int32)

    public var errorDescription: String? {
        switch self {
        case .unreadableKeychainValue:
            "O Keychain devolveu uma sessão OAuth de provedor inválida."
        case let .keychain(status):
            "Não foi possível acessar a sessão OAuth do provedor no Keychain (código \(status))."
        }
    }
}

/// Serviço separado do cofre de API keys e do OAuth do LiteLLM. Assim uma
/// chave, um proxy e uma assinatura não compartilham acidentalmente estado.
public struct KeychainAssistantProviderOAuthSessionStore:
    AssistantProviderOAuthSessionStoring, Sendable {

    private let service: String

    public init(service: String = "com.okamiops.okamiuni.provider-oauth") {
        self.service = service
    }

    public func store(_ session: AssistantProviderOAuthSession, for credentialID: String) throws {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        let data = try JSONEncoder().encode(session)
        let status = SecItemUpdate(
            query(credentialID) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        if status != errSecItemNotFound {
            throw AssistantProviderOAuthSessionStoreError.keychain(status: Int32(status))
        }

        var insert = query(credentialID)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw AssistantProviderOAuthSessionStoreError.keychain(status: Int32(added))
        }
    }

    public func session(for credentialID: String) throws -> AssistantProviderOAuthSession? {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        var lookup = query(credentialID)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AssistantProviderOAuthSessionStoreError.keychain(status: Int32(status))
        }
        guard let data = item as? Data,
              let decoded = try? JSONDecoder().decode(AssistantProviderOAuthSession.self, from: data)
        else {
            throw AssistantProviderOAuthSessionStoreError.unreadableKeychainValue
        }
        return decoded
    }

    public func removeSession(for credentialID: String) throws {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        let status = SecItemDelete(query(credentialID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AssistantProviderOAuthSessionStoreError.keychain(status: Int32(status))
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

public final class InMemoryAssistantProviderOAuthSessionStore:
    AssistantProviderOAuthSessionStoring, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [String: AssistantProviderOAuthSession] = [:]

    public init() {}

    public func store(_ session: AssistantProviderOAuthSession, for credentialID: String) throws {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        lock.lock()
        defer { lock.unlock() }
        storage[credentialID] = session
    }

    public func session(for credentialID: String) throws -> AssistantProviderOAuthSession? {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        lock.lock()
        defer { lock.unlock() }
        return storage[credentialID]
    }

    public func removeSession(for credentialID: String) throws {
        let credentialID = try AssistantCredentialValidation.credentialID(credentialID)
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: credentialID)
    }
}
